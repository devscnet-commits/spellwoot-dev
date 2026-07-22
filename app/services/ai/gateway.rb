# The AI Gateway — F1 happy-path, SHADOW only.
# Pipeline: message.received -> resolve_agent (caller) -> resolve_department -> assemble_context
#           -> retrieve_knowledge -> decide -> record ai_runs + ai_events.
# In shadow it NEVER replies, NEVER executes a tool, NEVER writes operational changes — it only
# records intention, runs and events.
class Ai::Gateway
  # Valores VÁLIDOS do campo `decision` no contrato do LLM (ver Ai::PromptCompiler#response_contract).
  # Qualquer outro valor é "fora do contrato" e cai na rede de segurança do dispatch (decision.unknown_kind).
  KNOWN_DECISION_KINDS = %w[reply invoke_tool handoff close noop].freeze

  def initialize(message:, agent_inbox:, mode: nil, content_override: nil)
    @message = message
    @agent_inbox = agent_inbox
    @agent = agent_inbox.agent
    @conversation = message.conversation
    @account = message.account
    # mode may be downgraded by the caller (team routing): a non-owner agent observes (shadow).
    @mode = mode || agent_inbox.mode
    # When grouping, the caller passes the whole customer burst as the content to consider.
    @content_override = content_override
    # Breadcrumb da etapa corrente do pipeline; o rescue do topo usa p/ tipar o erro (classify_error).
    @stage = nil
  end

  def run
    run_record = Ai::Run.create!(
      account_id: @account.id, conversation_id: @conversation.id, ai_agent_id: @agent.id,
      inbox_id: @message.inbox_id, run_type: 'decision', mode: @mode, status: 'running'
    )
    emit(run_record, 'message.received', { content: @message.content.to_s.first(500), message_id: @message.id })

    # Invisible worker: turn media (audio/image) into text the supervisor can use. Passa o profile
    # do agente para o OCR ler o worker de visão configurado (worker_overrides['ocr']).
    media_text = Ai::Workers::MediaProcessor.process(@message, @agent.operation_profile)
    emit(run_record, 'media.preprocessed', { text: media_text }) if media_text.present?
    base_content = @content_override.presence || @message.content
    effective_content = [base_content, media_text].compact.join("\n").strip

    @stage = :department
    department, resolution = Ai::DepartmentResolver.resolve(
      agent: @agent, inbox_id: @message.inbox_id, message_content: effective_content, conversation: @conversation
    )

    # A partir daqui NÃO é mais classificação de departamento: gravar o resultado e o estado é
    # infra/DB. Uma exceção aqui deve virar 'internal_error', não 'classification_failed' (ver
    # classify_error). Por isso o :department cobre SÓ a chamada de resolve acima.
    @stage = :persist
    # Fase 2: override de department pedido mas NÃO honrado (deletado/inativo/outra conta) -> tag de
    # visibilidade + segue normal (o department já veio do fluxo padrão). Nunca interrompe o run.
    flag_unavailable_department_override(resolution)
    emit(run_record, 'department.resolved', { department_id: department&.id, name: department&.name, method: resolution })
    return finalize(run_record, 'no_department') unless department

    run_record.update!(ai_department_id: department.id)

    # Config do departamento + gate de política (reply state) + caminho ask_resume — nada disso é
    # classificação; erro aqui é 'internal_error', não 'classification_failed'.
    @stage = :policy
    # Limite de caracteres da mensagem do cliente (anti-abuso/tokens). Ação configurável:
    # 'truncate' (padrão: corta nos N primeiros) ou 'ask_resume' (pede pro cliente resumir e
    # NÃO processa o texto gigante). Tratado abaixo, após o gate de resposta.
    max_input = department.behavior.to_h['max_input_chars'].to_i
    input_action = department.behavior.to_h['max_input_action'].presence || 'truncate'
    input_exceeded = max_input.positive? && effective_content.length > max_input
    effective_content = effective_content.first(max_input) if input_exceeded && input_action != 'ask_resume'

    # Single gate for every outward action (reply, tools, transfer/resolve): the AI only acts when
    # this conversation is effectively live — i.e. live binding + auto_attendance on + within hours
    # + reply_scope all/canary-match. Otherwise it observes (records intention) only, so a live
    # binding piloted "behind canary" never touches non-canary conversations.
    @acts_live =
      Ai::ReplyPolicy.effective_reply_state(mode: @mode, department: department, conversation: @conversation) == :live

    # Billing Fase 2: aviso proativo de saldo baixo (90% usado) + bloqueio ao ESGOTAR. Só ao vivo p/
    # o bloqueio; conta sem balance/plano ou com chave própria (custom_llm_api_key) = LIBERA
    # (fail-open). Ao esgotar, entrega ao humano com nota interna e NÃO roda o modelo (zero custo).
    maybe_notify_low_balance(run_record)
    if @acts_live && credit_exhausted?
      force_credit_handoff(run_record)
      return finalize(run_record, 'credit_exhausted')
    end

    # Mensagem acima do limite + ação "pedir resumo": avisa o cliente e encerra a execução
    # (não roda o modelo no texto gigante). 'truncate' segue normal (já cortado acima).
    if input_exceeded && input_action == 'ask_resume'
      message = department.behavior.to_h['max_input_message'].presence ||
                'Sua mensagem ficou longa demais para eu entender bem. Pode resumir em poucas linhas, por favor? 🙂'
      emit(run_record, 'input.too_long', { chars: effective_content.length, max: max_input })
      action_dispatcher.reply(department, message)
      return finalize(run_record, 'input_too_long')
    end

    # Fix 3b — SPLIT decisão/resposta (opt-in por perfil, SÓ ao vivo). OFF (default) NÃO entra aqui e o
    # fluxo único abaixo segue BYTE-IDÊNTICO (envelope com reply_text + tool_followup). ON substitui
    # decide+tool_followup por Fase A (decisão fria + tools de leitura) + Fase B (texto com a voz do perfil).
    return run_split(run_record, department, effective_content) if split_enabled?

    @stage = :knowledge
    # (Camada 3) Conhecimento SOB DEMANDA: o worker (opt-in) roda UMA vez por turno e decide se busca e de
    # qual kind. Só reivindica o turno cedo QUANDO vai rodar o worker (live + texto + worker on) — assim o
    # worker fica DENTRO da idempotência do BUG 1 (claim perdido em re-exec/2º binding => worker NÃO roda),
    # e o caminho worker-OFF (default) segue IDÊNTICO a hoje (claim continua dentro do track_step).
    active_step = @acts_live ? state_manager.current_step(department) : nil
    judge_result =
      if @acts_live && effective_content.present? && state_manager.judge_enabled? && state_manager.claim_turn(@message)
        state_manager.run_turn_judge(active_step, effective_content)
      end

    kn = resolve_knowledge(run_record, department, active_step, judge_result, effective_content)
    knowledge = kn[:chunks]
    emit(run_record, 'knowledge.retrieved',
         { count: knowledge.size, preview: knowledge.first(2), kinds: kn[:kinds], source: kn[:source] })
    run_record.update!(knowledge_count: knowledge.size)

    memory = Ai::AgentMemory.find_by(conversation_id: @conversation.id, ai_agent_id: @agent.id)
    customer_memory = @conversation.contact_id &&
                      Ai::CustomerMemory.find_by(contact_id: @conversation.contact_id, account_id: @account.id)
    tools  = department.tools.active.to_a
    @stage = :context
    system_prompt = Ai::PromptCompiler.compile(
      agent: @agent, department: department, knowledge: knowledge, memory: memory, tools: tools,
      collected: (@conversation.contact&.custom_attributes || {})
        .merge(@conversation.additional_attributes&.dig('ai_collected_facts') || {})
        .merge(@conversation.custom_attributes || {}),
      fillable_attributes: context_builder.fillable_attributes(department),
      customer_memory: customer_memory,
      # Índice determinístico da etapa (fonte de verdade no servidor). O PromptCompiler ancora o
      # modelo nesta etapa em vez de deixá-lo se autolocalizar. StateManager#track_step avança no fim.
      step_index: (@conversation.additional_attributes || {})['ai_step_index'].to_i
    )
    emit(run_record, 'context.assembled', { prompt_chars: system_prompt.length, tools: tools.map(&:name) })

    @stage = :decision
    result = Ai::ModelRouter.decide(
      profile: @agent.operation_profile, system_prompt: system_prompt,
      user_message: context_builder.user_message(effective_content), account_id: @account.id, json: true
    )
    # BYOK (billing Fase 3): se a chave PRÓPRIA do cliente falhou por auth (401), sinaliza com tag,
    # refaz a decisão na chave global da SCNET e cobra 1 crédito SCNET desse retry. Substitui `result`.
    result = maybe_byok_fallback(run_record, system_prompt, effective_content, result)
    run_record.update!(
      provider: result[:provider], model: result[:model],
      tokens_in: result[:tokens_in], tokens_out: result[:tokens_out], cached_tokens: result[:cached_tokens],
      cost: result[:cost], latency_ms: result[:latency_ms],
      decision: result[:decision] || {}, status: result[:status],
      error_type: (result[:status] == 'error' ? 'provider_error' : nil)
    )
    emit(run_record, 'decision.made',
         { decision: result[:decision], cost: result[:cost], latency_ms: result[:latency_ms],
           temperature: result[:temperature], cached_tokens: result[:cached_tokens] },
         run_id: run_record.id)

    # Track which step the conversation is on so message grouping can use that step's delay; also
    # fires the step's completion automations when the model signals step_completed (audited actions
    # reuse this run's dispatcher). message_text alimenta a extração determinística de slot (Camada A).
    # track_step swallows its own errors — never breaks the Gateway. Devolve um sinal quando a etapa de
    # slot travou por N turnos (Camada B) — tratado logo abaixo.
    step_signal = nil
    if @acts_live
      step_signal = state_manager.track_step(department, result[:decision] || {}, dispatcher: action_dispatcher,
                                                                                  run: run_record, message_text: effective_content,
                                                                                  message: @message, judge_result: judge_result)
      # Grava os dados coletados (cidade, plano, etc.) nos atributos da conversa, conforme o modelo
      # devolveu em `attributes`. Só chaves que batem com um attribute_key real do department (o resto
      # vira attributes.unknown_key, sem sujar o JSON). Assim os campos são alimentados e reaproveitados.
      state_manager.persist_attributes((result[:decision] || {})['attributes'], department, source: :supervisor)
    end

    # Camada B (rede de segurança do avanço-por-slot): a IA ficou presa numa etapa de COLETA por N
    # mensagens sem obter o dado. NÃO forçamos avanço (cadastro incompleto): avisamos o cliente e
    # TRANSFERIMOS para humano, com motivo claro no resumo. Curto-circuita antes de qualquer dispatch.
    if step_signal.is_a?(Hash) && step_signal[:stuck_handoff]
      force_stuck_handoff(run_record, department, step_signal[:stuck_handoff])
      state_manager.update_memory
      return finalize(run_record, 'recorded')
    end

    # Tool handling. SHADOW never executes — only records intention. LIVE runs the executor,
    # which executes the tool immediately (tools are autonomous).
    @stage = :tool
    intended_tool = result.dig(:decision, 'tool')
    execution = nil
    if intended_tool.present?
      tool = department.tools.active.find_by(name: intended_tool['name'])
      if @acts_live && tool
        execution = Ai::ToolExecutor.new(
          tool: tool, input: intended_tool['input'], conversation: @conversation, mode: @mode, run: run_record
        ).perform
        emit(run_record, 'tool.executed',
             { tool: tool.name, status: execution.status, execution_id: execution.id })
      else
        emit(run_record, 'tool.intended', { tool: intended_tool, executed: false, reason: action_dispatcher.not_acting_reason(tool) })
      end
    end

    # An `invoke_tool` decision only runs the tool — it carries no reply, so the conversation would
    # stall. Take a SECOND turn feeding the tool result back so the AI answers the customer with it.
    # Single hop (we don't execute another tool) to avoid loops; `result` is replaced for dispatch.
    if intended_tool.present? && @acts_live && execution&.status == 'executed'
      # 2ª chamada só REDIGE a resposta pós-ferramenta (não avança etapa, não grava attributes, não roda
      # outra ferramenta) -> usa um prompt ENXUTO (sem playbook/âncora/estado-da-coleta/lead_vars/tools)
      # para cortar o custo do reenvio. Recompilado AQUI (só quando há followup), reusando RAG/memória já
      # carregados. Ver Ai::PromptCompiler.compile(followup: true).
      followup_prompt = Ai::PromptCompiler.compile(
        agent: @agent, department: department, knowledge: knowledge, memory: memory,
        tools: [], customer_memory: customer_memory, followup: true,
        # A âncora e o estado da coleta do followup precisam do MESMO estado da 1ª chamada: em que etapa
        # estamos e o que já foi coletado (senão o followup repergunta / pede dado de outra etapa).
        collected: (@conversation.contact&.custom_attributes || {})
          .merge(@conversation.additional_attributes&.dig('ai_collected_facts') || {})
          .merge(@conversation.custom_attributes || {}),
        step_index: (@conversation.additional_attributes || {})['ai_step_index'].to_i
      )
      result = tool_followup(run_record, followup_prompt, effective_content, intended_tool, execution)
    end

    @stage = :dispatch
    decision_kind = (result[:decision] || {})['decision']

    # Bug 3 hotfix: the model returned something we couldn't parse into a decision. NEVER dispatch it
    # to the customer (raw JSON/config used to leak via the reply fallback) — mark the run as an error
    # for review and stop before any action.
    if decision_kind == 'unparsed'
      run_record.update!(error_type: 'unparsed_decision')
      emit(run_record, 'decision.unparsed', {})
      return finalize(run_record, 'error')
    end

    # Intelligent handoff / close. Shadow records intention; live executes the native action.
    handoff = Ai::HandoffEvaluator.evaluate(
      decision: result[:decision] || {}, department: department
    )
    if handoff[:handoff]
      # Try AI->AI routing first (to an allowed agent); otherwise hand to a human.
      routed = @acts_live && handoff_coordinator.route_to_ai(result[:decision] || {})
      unless routed
        # Idempotência: se JÁ houve handoff nesta conversa e ela seguiu SEM responsável (1ª atribuição
        # falhou), NÃO reenvia a mensagem de transição — só refaz a atribuição (transfer + assign),
        # evitando a mensagem duplicada quando o cliente cobra e o fluxo re-executa.
        retrying_handoff = @conversation.additional_attributes&.dig('ai_handoff').present? &&
                           @conversation.assignee_id.blank?
        # Tell the customer we're handing off (the model's "transferindo você..." text), THEN
        # transfer (reopen + unassign for a human). Without the reply the customer saw silence.
        action_dispatcher.reply(department, (result[:decision] || {})['reply_text']) unless retrying_handoff
        team_id = handoff_coordinator.human_team_id(result[:decision] || {})
        input = { 'unassign' => true }
        input['team_id'] = team_id if team_id # roteia para o time; senão mantém o atual
        action_dispatcher.execute_action('conversation.transfer', input, run_record, 'handoff', extra: { reason: handoff[:reason], team_id: team_id })
        # Atribuição DEPOIS do trabalho da IA: o próprio handoff atribui um humano (round-robin
        # entre os agentes online do time/caixa). Mantenha a auto-atribuição da caixa DESLIGADA
        # para a IA atender primeiro; aqui é o único ponto que entrega a um agente. reason vem do
        # HandoffEvaluator (modelo_pediu_transferencia / palavra_chave) -> dispara o resumo do handoff.
        handoff_coordinator.assign_human(team_id, reason: handoff[:reason]) if @acts_live
      end
    elsif decision_kind == 'close'
      # Despedida antes de resolver (fix do encerramento silencioso): a mensagem da aba Finalização
      # (close_rules['message']) tem prioridade; senão o reply_text que o modelo gerou nesta decisão
      # (antes descartado); se nenhum existir, fecha em silêncio como antes. Usa o mesmo mecanismo de
      # reply (respeita live/shadow, reply_scope e max_replies).
      farewell = close_farewell(department, result[:decision] || {})
      action_dispatcher.reply(department, farewell) if farewell.present?
      action_dispatcher.execute_action('conversation.resolve', {}, run_record, 'close')
    elsif decision_kind == 'reply'
      safe_reply = guard_against_loop(run_record, system_prompt, effective_content,
                                      (result[:decision] || {})['reply_text'])
      action_dispatcher.reply(department, safe_reply) if safe_reply
    elsif intended_tool.present? && @acts_live
      # Safety net: a tool ran but the follow-up decision still isn't a plain reply/close/handoff —
      # send whatever text we have so the customer is never left waiting after a tool call.
      action_dispatcher.reply(department, (result[:decision] || {})['reply_text'])
    elsif KNOWN_DECISION_KINDS.include?(decision_kind)
      # noop (a IA escolheu não agir) ou invoke_tool sem execução ao vivo: valores VÁLIDOS do contrato,
      # sem ação de saída aqui. Não é desvio — não registra decision.unknown_kind.
    else
      # Rede de segurança: decision FORA do contrato (ex.: "text"). Sem isto, o Gateway descartava um
      # reply_text VÁLIDO em SILÊNCIO (cliente sem resposta, sem handoff, sem erro). Com texto, trata
      # como reply (mesmo caminho — passa por LoopGuard e pelo consumo de crédito do reply). Sem texto,
      # só registra o desvio para observabilidade (não some sem rastro).
      unknown_reply = (result[:decision] || {})['reply_text']
      if unknown_reply.present?
        emit(run_record, 'decision.unknown_kind', { decision: decision_kind, handled: 'reply' })
        safe_reply = guard_against_loop(run_record, system_prompt, effective_content, unknown_reply)
        action_dispatcher.reply(department, safe_reply) if safe_reply
      else
        emit(run_record, 'decision.unknown_kind', { decision: decision_kind, handled: 'none' })
      end
    end

    state_manager.update_memory
    finalize(run_record, result[:status] == 'error' ? 'error' : 'recorded')
  rescue StandardError => e
    error_type = classify_error(e)
    # Loga a etapa e a categoria junto do erro — o "porquê" fica no log; o "o quê" (agregável) na run.
    Rails.logger.error "[Ai::Gateway] conv=#{@conversation&.id} stage=#{@stage} type=#{error_type} #{e.class}: #{e.message}"
    run_record.update!(status: 'error', error_type: error_type) if defined?(run_record) && run_record&.persisted?
    nil
  end

  private

  # (Camadas 3/4) Decide a busca de conhecimento a partir da INTENÇÃO do worker. Devolve
  # { chunks:, kinds:, source: } — source audita a origem:
  #  - judge_result nil (worker OFF/default, shadow, ou claim perdido) -> RAG como hoje (full, sem filtro,
  #    todo turno). source 'all' — REGRESSÃO TOTAL do comportamento atual.
  #  - worker FALHOU -> fallback: full RAG + evento knowledge.fallback (auditável). source 'fallback'.
  #  - asks_about != 'nada' -> busca kinds:[asks_about] com a QUERY do worker (não o texto cru, que deu o
  #    resultado ruim). source 'worker'.
  #  - etapa apresenta planos/catálogo (heurística por instrução) -> busca produtos. source 'step'.
  #  - senão -> NÃO busca (economia) + evento knowledge.skipped. source 'none'.
  def resolve_knowledge(run_record, department, step, judge_result, query_text)
    return search_knowledge(department, nil, query_text, 'all') if judge_result.nil?

    if judge_result[:status].to_s == 'failed'
      emit(run_record, 'knowledge.fallback', { reason: judge_result[:reason].to_s.first(80) })
      return search_knowledge(department, nil, query_text, 'fallback')
    end

    asks = judge_result[:asks_about].to_s
    return search_knowledge(department, [asks], judge_result[:query].presence || query_text, 'worker') if asks.present? && asks != 'nada'
    return search_knowledge(department, ['produto'], 'planos e preços', 'step') if step_wants_products?(step)

    emit(run_record, 'knowledge.skipped', { reason: 'no_question_no_catalog_step' })
    { chunks: [], kinds: nil, source: 'none' }
  end

  def search_knowledge(department, kinds, query, source)
    chunks = Ai::KnowledgeRetriever.retrieve(query: query, account_id: @account.id,
                                             department_id: department.id, kinds: kinds)
    { chunks: chunks, kinds: kinds, source: source }
  end

  # "Esta etapa apresenta planos/catálogo?" — derivado da INSTRUÇÃO da etapa (sem config nova, sem tocar
  # no playbook): heurística por palavras que só aparecem quando a etapa é de apresentar produto/preço.
  # Menos frágil que casar o nome da etapa; a instrução é o texto que o usuário já escreveu.
  STEP_PRODUCTS_RE = /\b(planos?|produtos?|cat[áa]logo|pre[çc]os?|mensalidade)\b/i
  def step_wants_products?(step)
    return false unless step.is_a?(Hash)

    STEP_PRODUCTS_RE.match?((step['instructions'] || step[:instructions]).to_s)
  end

  # Montagem do contexto textual do modelo (histórico + citação + atributos preenchíveis), extraído
  # do Gateway (Passo 2 da quebra do God object). Memoizado — criado 1x por run, sob demanda.
  def context_builder
    @context_builder ||= Ai::ContextBuilder.new(
      conversation: @conversation, message: @message, account: @account
    )
  end

  # Escritas de estado derivado (atributos coletados, etapa atual, memória), extraído do Gateway
  # (Passo 4). Memoizado — só depende de @conversation/@agent (sem restrição de ordem).
  def state_manager
    @state_manager ||= Ai::StateManager.new(conversation: @conversation, agent: @agent)
  end

  # Execução de ações do pipeline (reply + capabilities nativas), extraído do Gateway (Passo 3).
  # Memoizado — depende de @acts_live, então SÓ é acessado depois da resolução do gate (linha ~52).
  def action_dispatcher
    # as_human é constante por run (o agente é fixo), então injetamos na construção em vez de repetir
    # nos 4 call-sites de reply. No modo humano o dispatcher quebra a resposta em várias mensagens.
    @action_dispatcher ||= Ai::ActionDispatcher.new(
      conversation: @conversation, account: @account, mode: @mode, acts_live: @acts_live,
      as_human: @agent.identify_as == 'human'
    )
  end

  # Nomes de classes (comparados por NOME p/ não exigir a constante carregada — ex.: PG/Faraday
  # podem não estar em memória) que denotam timeout/queda de conexão.
  TIMEOUT_ERROR_NAMES = %w[
    Timeout::Error Net::OpenTimeout Net::ReadTimeout Errno::ETIMEDOUT
    Redis::TimeoutError Faraday::TimeoutError
    PG::QueryCanceled ActiveRecord::StatementTimeout ActiveRecord::QueryCanceled
  ].freeze

  # Traduz a exceção que borbulhou até o rescue do topo numa categoria de Ai::Run::ERROR_TYPES,
  # cruzando a ETAPA onde estourou (@stage) com a CLASSE da exceção (timeout tem classe
  # reconhecível). Retorna SEMPRE um valor válido de ERROR_TYPES; 'unknown' é o piso honesto.
  #
  # CORTE HISTÓRICO (refactor dos stages, jul/2026): antes, a janela :department cobria também
  # persistência/política/ask_resume, então erros de DB/policy caíam em 'classification_failed'.
  # Agora :persist/:policy têm rótulo próprio ('internal_error'). Logo, a partir do deploy deste
  # commit, a queda de 'classification_failed' e a subida de 'internal_error' é RECLASSIFICAÇÃO —
  # não mudança de comportamento. O projeto está em sandbox/sem prod, então não há degrau real hoje;
  # este registro fica pronto para quando a série histórica passar a importar.
  def classify_error(exception)
    timed_out = timeout_error?(exception)
    case @stage
    when :knowledge        then 'knowledge_timeout'             # busca RAG/pgvector
    when :tool             then 'tool_failed'                   # executor de ferramenta estourou
    when :department       then 'classification_failed'         # SÓ a resolução do departamento
    when :persist, :policy then 'internal_error'               # write de estado / gate de política (não é classificação)
    when :decision         then timed_out ? 'provider_timeout' : 'provider_error'
    else                        timed_out ? 'provider_timeout' : 'unknown'
    end
  rescue StandardError
    'unknown'
  end

  # Reconhece timeouts por classe (herança, não igualdade) ou pela mensagem, sem referenciar a
  # constante da classe diretamente (evita NameError se o gem não estiver carregado).
  def timeout_error?(exception)
    ancestors = exception.class.ancestors.filter_map(&:name)
    (ancestors & TIMEOUT_ERROR_NAMES).any? || exception.message.to_s.downcase.include?('timeout')
  end

  # Second model turn after a tool ran: feeds the tool output back so the AI replies to the customer
  # with the result (e.g. coverage lookup -> "sim, atendemos sua cidade"). Returns the new decision
  # for the normal dispatch. Single hop — it never triggers another tool execution.
  def tool_followup(run_record, system_prompt, user_message, tool_call, execution)
    followup_message = "#{user_message}\n\n[Resultado da ferramenta \"#{tool_call['name']}\"]:\n" \
                       "#{execution.output.to_json}\n\n" \
                       'Use esse resultado para responder ao cliente agora (decision: "reply").'
    result = Ai::ModelRouter.decide(
      profile: @agent.operation_profile, system_prompt: system_prompt,
      user_message: followup_message, account_id: @account.id, json: true
    )
    emit(run_record, 'tool.followup',
         { decision: result[:decision], cost: result[:cost], latency_ms: result[:latency_ms],
           prompt_chars: system_prompt.length })
    result
  rescue StandardError => e
    Rails.logger.error "[Ai::Gateway#tool_followup] #{e.class}: #{e.message}"
    { decision: {} }
  end

  # Cluster de handoff/atribuição extraído do Gateway (Passo 1 da quebra do God object): route IA->IA,
  # resolução do time de destino e entrega a um humano. Memoizado — criado 1x por run, sob demanda.
  def handoff_coordinator
    @handoff_coordinator ||= Ai::HandoffCoordinator.new(
      conversation: @conversation, account: @account, agent: @agent, message: @message
    )
  end

  # Aplica a tag de visibilidade quando um override de department foi pedido mas não pôde ser honrado
  # (department deletado/inativo/de outra conta). Best-effort: NUNCA interrompe o run. Reusa o handler
  # conversation_add_label direto (sem auditoria/gate live-shadow) porque roda no stage :department,
  # antes do action_dispatcher existir — e é um sinal operacional que deve aparecer mesmo em shadow.
  def flag_unavailable_department_override(resolution)
    return if resolution == 'override'
    return if @conversation.additional_attributes&.dig('ai_department_override').blank?

    Ai::CapabilityRegistry.execute('conversation.add_label', conversation: @conversation,
                                                             input: { 'label' => 'department-override-indisponivel' })
  rescue StandardError => e
    Rails.logger.error "[Ai::Gateway#flag_unavailable_department_override] #{e.class}: #{e.message}"
  end

  # Rede de segurança anti-loop de repergunta (defesa em profundidade). Se o reply_text repete as 2
  # últimas respostas (parafraseando) COM o cliente respondendo entre elas, tenta 1 vez com um nudge;
  # se AINDA repetir, força handoff e NÃO envia. Retorna o texto a enviar, ou nil (quando escalou p/
  # handoff). Só age ao vivo; em shadow devolve o texto original (sem efeito colateral).
  def guard_against_loop(run_record, system_prompt, user_message, reply_text)
    return reply_text unless @acts_live && reply_text.present?

    guard = Ai::LoopGuard.new(conversation: @conversation, current_run: run_record)
    return reply_text unless guard.loop?(reply_text)

    emit(run_record, 'reply.loop_detected', { chars: reply_text.length })
    retried = loop_retry(run_record, system_prompt, user_message)
    new_reply = (retried[:decision] || {})['reply_text'].to_s

    if new_reply.present? && !guard.loop?(new_reply)
      # A resposta regenerada saiu do loop: passa a valer (mantém a run auditável coerente).
      run_record.update!(decision: retried[:decision]) if retried[:decision].is_a?(Hash)
      return new_reply
    end

    # Loop persistiu mesmo após o retry -> handoff forçado, sem enviar a resposta problemática.
    force_loop_handoff(run_record)
    nil
  end

  # Regenera a decisão com um nudge anti-repetição no fim do system prompt. UMA tentativa só (nunca
  # entra em loop de retry). Devolve o result do ModelRouter (ou vazio em erro).
  def loop_retry(run_record, system_prompt, user_message)
    nudge = "\n\nATENÇÃO: você já fez esta mesma pergunta/confirmação antes, de forma muito parecida. " \
            'NÃO repita. Trate o que o cliente já respondeu como confirmado e AVANCE para o próximo ' \
            'passo; se não for possível avançar, peça ajuda humana.'
    result = Ai::ModelRouter.decide(
      profile: @agent.operation_profile, system_prompt: "#{system_prompt}#{nudge}",
      user_message: user_message, account_id: @account.id, json: true
    )
    emit(run_record, 'reply.loop_retry', { status: result[:status] })
    result
  rescue StandardError => e
    Rails.logger.error "[Ai::Gateway#loop_retry] #{e.class}: #{e.message}"
    { decision: {} }
  end

  # Handoff forçado quando o loop persiste após o retry: entrega ao humano no time PADRÃO do agente,
  # reaproveitando o mesmo fluxo do handoff normal (transfer + assign). Não envia texto ao cliente.
  def force_loop_handoff(run_record)
    team_id = handoff_coordinator.human_team_id({})
    input = { 'unassign' => true }
    input['team_id'] = team_id if team_id
    action_dispatcher.execute_action('conversation.transfer', input, run_record, 'handoff', extra: { reason: 'loop' })
    handoff_coordinator.assign_human(team_id, reason: 'loop')
    emit(run_record, 'handoff.loop_forced', { team_id: team_id })
  rescue StandardError => e
    Rails.logger.error "[Ai::Gateway#force_loop_handoff] #{e.class}: #{e.message}"
  end

  # Camada B da rede de segurança do avanço-por-slot: a IA ficou presa numa etapa de COLETA por N
  # mensagens sem obter o dado (o modelo não devolveu o attribute e a extração determinística não pegou).
  # Em vez de FORÇAR o avanço com dado faltando (cadastro incompleto), na sequência: (1) AVISA o cliente,
  # (2) TRANSFERE para humano reaproveitando o mesmo fluxo do force_loop_handoff (transfer + assign), (3)
  # registra o motivo específico no resumo do handoff (o reason vira o "Resumo da transferência"), (4)
  # emite step.stuck_handoff para telemetria (quais etapas travam mais).
  def force_stuck_handoff(run_record, department, info)
    action_dispatcher.reply(department, stuck_handoff_warning(department)) # aviso ANTES da transferência
    reason = stuck_handoff_reason(info)
    team_id = handoff_coordinator.human_team_id({})
    input = { 'unassign' => true }
    input['team_id'] = team_id if team_id
    action_dispatcher.execute_action('conversation.transfer', input, run_record, 'handoff', extra: { reason: reason })
    handoff_coordinator.assign_human(team_id, reason: reason) # reason livre -> vira o Resumo da transferência
    emit(run_record, 'step.stuck_handoff',
         { attribute: info[:attribute], step_name: info[:step_name], turns: info[:turns] })
  rescue StandardError => e
    Rails.logger.error "[Ai::Gateway#force_stuck_handoff] #{e.class}: #{e.message}"
  end

  # Mensagem de aviso ao cliente antes de transferir (configurável via transfer_rules['stuck_message'];
  # senão uma default acolhedora em pt-BR — o cliente não pode sentir corte seco).
  def stuck_handoff_warning(department)
    (department.transfer_rules || {})['stuck_message'].presence ||
      'Vou te encaminhar para um especialista do nosso time que vai te ajudar melhor com isso, tá? 😊'
  end

  # Motivo específico e honesto — o HandoffSummaryGenerator usa este texto livre (reason desconhecido)
  # no "Resumo da transferência". Usa o nome amigável da etapa quando houver, não só a chave técnica.
  def stuck_handoff_reason(info)
    label = info[:step_name].presence || info[:attribute]
    "Transferido automaticamente: a IA tentou coletar \"#{label}\" por #{info[:turns]} mensagens sem " \
      'sucesso. Encaminhado para atendimento humano para não travar o cliente.'
  end

  # Saldo de créditos de IA relevante para enforcement (billing Fase 2). nil = NÃO enforça (fail-open):
  # conta sem balance/plano, ou conta com chave própria (custom_llm_api_key — BYOK). A flag é sempre
  # false hoje (Fase 3 não implementada); o check é fail-safe, preparado pro futuro.
  def billing_balance
    return nil if @account.feature_enabled?('custom_llm_api_key')

    @account.ai_credit_balance
  end

  def credit_exhausted?
    balance = billing_balance
    balance.present? && balance.total <= 0
  end

  # Aviso proativo de 90% usado: quando plan_credits <= 10% do teto do plano, notifica a SCHNET UMA
  # vez por ciclo (guardado por low_balance_notified_at, resetado na renovação). O short-circuit pelo
  # flag roda ANTES da query do plano, então o caso comum (já avisado) é barato.
  def maybe_notify_low_balance(run_record)
    balance = billing_balance
    return if balance.nil? || balance.low_balance_notified_at.present?

    cap = current_plan_credits_cap
    return if cap <= 0 || balance.plan_credits > cap * 0.1

    AdministratorNotifications::CreditRequestMailer.low_balance_warning(@account, balance.total, cap).deliver_later
    balance.update!(low_balance_notified_at: Time.current)
    emit(run_record, 'credit.low_balance_notified', { remaining: balance.total, cap: cap })
  rescue StandardError => e
    Rails.logger.error "[Ai::Gateway#maybe_notify_low_balance] #{e.class}: #{e.message}"
  end

  def current_plan_credits_cap
    @account.subscriptions.current.first&.plan&.ai_credits_included.to_i
  end

  # Handoff forçado quando o saldo de créditos de IA esgota: nota interna + entrega ao humano no time
  # PADRÃO do agente, reaproveitando o mesmo fluxo do force_loop_handoff (transfer + assign). NÃO
  # envia texto ao cliente (a IA simplesmente não responde; um humano assume).
  def force_credit_handoff(run_record)
    action_dispatcher.internal_note('⚠️ Crédito de IA esgotado — atendimento transferido para um humano.')
    team_id = handoff_coordinator.human_team_id({})
    input = { 'unassign' => true }
    input['team_id'] = team_id if team_id
    action_dispatcher.execute_action('conversation.transfer', input, run_record, 'handoff', extra: { reason: 'credit_exhausted' })
    handoff_coordinator.assign_human(team_id, reason: 'credit_exhausted')
    emit(run_record, 'handoff.credit_exhausted', { team_id: team_id })
  rescue StandardError => e
    Rails.logger.error "[Ai::Gateway#force_credit_handoff] #{e.class}: #{e.message}"
  end

  # BYOK (billing Fase 3): a chave própria do cliente foi recusada por auth (401). Só age ao vivo e só
  # quando a 1ª chamada REALMENTE usou a chave própria (account_provider_key presente = feature ligada +
  # chave no Hub) — assim um 401 da chave global da SCNET NÃO é rotulado como "chave-propria-falhou".
  # Aplica a tag de visibilidade, refaz a decisão forçando a chave global e, se o retry der certo, cobra
  # 1 crédito SCNET (auto-provisiona um AiCreditBalance zerado se a conta BYOK ainda não tiver um — daí a
  # Fase 2 assume o handoff por saldo esgotado nas próximas mensagens). Best-effort: qualquer erro
  # devolve o result original (a IA segue o caminho de erro normal).
  def maybe_byok_fallback(run_record, system_prompt, user_message, result)
    return result unless @acts_live
    return result unless result[:status] == 'error' && result[:error_type] == 'auth_error'
    return result if Ai::ModelRouter.account_provider_key(@account.id, result[:provider]).blank?

    apply_label('chave-propria-falhou')
    emit(run_record, 'decision.byok_fallback', { provider: result[:provider] })
    retried = Ai::ModelRouter.decide(
      profile: @agent.operation_profile, system_prompt: system_prompt,
      user_message: context_builder.user_message(user_message), account_id: @account.id, json: true,
      force_global_key: true
    )
    consume_byok_fallback_credit if retried[:status] != 'error'
    retried
  rescue StandardError => e
    Rails.logger.error "[Ai::Gateway#maybe_byok_fallback] #{e.class}: #{e.message}"
    result
  end

  # Cobra 1 crédito SCNET do fallback BYOK, FURANDO o short-circuit de billing_balance (que retorna nil
  # para contas custom_llm_api_key): acessa o AiCreditBalance direto, auto-provisionando um zerado se
  # ainda não existir. Sem saldo, o InsufficientCredits é engolido (a resposta já sai; a Fase 2 bloqueia
  # a partir da próxima mensagem, pois agora existe um balance esgotado).
  def consume_byok_fallback_credit
    balance = AiCreditBalance.find_or_create_by(account_id: @account.id)
    balance.consume!(1)
  rescue AiCreditBalance::InsufficientCredits => e
    Rails.logger.info "[Ai::Gateway] fallback BYOK sem saldo SCNET: #{e.message}"
  rescue StandardError => e
    Rails.logger.error "[Ai::Gateway#consume_byok_fallback_credit] #{e.class}: #{e.message}"
  end

  # Tag de visibilidade best-effort (mesmo handler direto do flag_unavailable_department_override).
  def apply_label(label)
    Ai::CapabilityRegistry.execute('conversation.add_label', conversation: @conversation, input: { 'label' => label })
  rescue StandardError => e
    Rails.logger.error "[Ai::Gateway#apply_label] #{e.class}: #{e.message}"
  end

  # Mensagem de despedida ao encerrar proativamente (decision 'close'): mensagem da Finalização
  # (close_rules['message']) tem prioridade; senão o reply_text da própria decisão; senão nil (silêncio).
  def close_farewell(department, decision)
    department.close_rules.to_h['message'].presence || decision['reply_text'].presence
  end

  # ============================ SPLIT decisão/resposta (Fix 3b) ============================
  # Ligado por perfil (worker_overrides['split_decision_reply']['mode']=='on') E só ao vivo. OFF = fluxo
  # único byte-idêntico (não passa por aqui). fase_a_mode: 'single' (default: schema+tools na MESMA
  # chamada) | 'a1a2' (tools sem schema -> depois schema sem tools) — flag INTERNO de operação.
  def split_enabled?
    return false unless @acts_live

    @agent.operation_profile&.worker(:split_decision_reply)&.dig('mode').to_s == 'on'
  end

  def fase_a_mode
    @agent.operation_profile&.worker(:split_decision_reply)&.dig('fase_a_mode').to_s.presence || 'single'
  end

  def split_collected
    (@conversation.contact&.custom_attributes || {})
      .merge(@conversation.additional_attributes&.dig('ai_collected_facts') || {})
      .merge(@conversation.custom_attributes || {})
  end

  # Orquestra as duas fases. Contexto do turno em @sp_* para não inflar as assinaturas dos helpers.
  def run_split(run_record, department, effective_content)
    @stage = :decision
    @sp_department = department
    @sp_content = effective_content
    @sp_memory = Ai::AgentMemory.find_by(conversation_id: @conversation.id, ai_agent_id: @agent.id)
    @sp_customer_memory = @conversation.contact_id &&
                          Ai::CustomerMemory.find_by(contact_id: @conversation.contact_id, account_id: @account.id)
    @sp_action_tools = department.tools.active.to_a
    @sp_collected = split_collected
    @sp_step_index = (@conversation.additional_attributes || {})['ai_step_index'].to_i
    @sp_reads = []

    result = run_fase_a(run_record)
    if result[:status] == 'error'
      record_phase(run_record, result, 'decision')
      # auth/credencial = falha PERSISTENTE: refazer a decisão só desperdiça uma 2ª chamada cara -> ABORTA.
      if result[:error_type] == 'auth_error'
        emit(run_record, 'split.fase_a_error', { error_type: 'auth_error' })
        return finalize(run_record, 'error')
      end
      # transitório (provider_error/timeout/internal) -> fallback ao fluxo único (envelope + tool_followup).
      emit(run_record, 'split.fallback', { reason: result[:error_type] || 'fase_a_failed' })
      return run_single_fallback(run_record, department, effective_content)
    end

    @stage = :persist
    step_signal = state_manager.track_step(department, result[:decision] || {}, dispatcher: action_dispatcher,
                                                                                run: run_record, message_text: effective_content,
                                                                                message: @message)
    state_manager.persist_attributes((result[:decision] || {})['attributes'], department, source: :supervisor)
    if step_signal.is_a?(Hash) && step_signal[:stuck_handoff]
      force_stuck_handoff(run_record, department, step_signal[:stuck_handoff])
      state_manager.update_memory
      return finalize(run_record, 'recorded')
    end

    @stage = :tool
    intended_tool = result.dig(:decision, 'tool')
    execution = execute_action_tool(run_record, department, intended_tool)

    @stage = :dispatch
    decision_kind = (result[:decision] || {})['decision']
    if decision_kind == 'unparsed'
      run_record.update!(error_type: 'unparsed_decision')
      emit(run_record, 'decision.unparsed', {})
      return finalize(run_record, 'error')
    end

    handoff = Ai::HandoffEvaluator.evaluate(decision: result[:decision] || {}, department: department)
    if handoff[:handoff]
      dispatch_split_handoff(run_record, department, result[:decision] || {}, handoff)
    elsif decision_kind == 'close'
      dispatch_split_close(run_record, department)
    elsif decision_kind == 'reply' || (intended_tool.present? && execution&.status == 'executed')
      dispatch_split_reply(run_record, department)
    elsif KNOWN_DECISION_KINDS.include?(decision_kind)
      # noop / invoke_tool sem execução ao vivo — sem saída (mesma semântica do fluxo único).
    else
      emit(run_record, 'decision.unknown_kind', { decision: decision_kind, handled: 'none' })
    end

    state_manager.update_memory
    finalize(run_record, 'recorded')
  end

  # FASE A — decisão FRIA (temp 0.2), prompt enxuto (sem RAG/persona) + tools NATIVAS de leitura + schema
  # SEM reply_text. Grava a run de DECISÃO (tokens/custo). Devolve o result normalizado, ou nil (falha ->
  # o caller cai no fallback do fluxo único).
  def run_fase_a(run_record)
    system_prompt = Ai::PromptCompiler.decision_prompt(
      agent: @agent, department: @sp_department, tools: @sp_action_tools, collected: @sp_collected,
      fillable_attributes: context_builder.fillable_attributes(@sp_department), step_index: @sp_step_index
    )
    emit(run_record, 'context.assembled', { phase: 'A', prompt_chars: system_prompt.length, tools: @sp_action_tools.map(&:name) })
    native = native_read_tools(run_record)
    result = fase_a_mode == 'a1a2' ? run_fase_a1a2(run_record, system_prompt, native) : run_fase_a_single(system_prompt, native)
    # SINALIZA o tipo da falha ao run_split (auth_error aborta; transitório cai no fallback). Retorna o
    # result do ModelRouter (que já traz :status/:error_type); exceção interna -> internal_error.
    return fase_a_error('internal_error') if result.nil?
    return result if result[:status] == 'error'

    record_phase(run_record, result, 'decision')
    emit(run_record, 'decision.made',
         { phase: 'A', decision: result[:decision], cost: result[:cost], cached_tokens: result[:cached_tokens],
           temperature: result[:temperature], mode: fase_a_mode }, run_id: run_record.id)
    result
  rescue StandardError => e
    Rails.logger.error "[Ai::Gateway#run_fase_a] #{e.class}: #{e.message}"
    fase_a_error('internal_error')
  end

  # Result de FALHA da Fase A com o TIPO (para o run_split decidir abortar x fallback). Tokens 0 para não
  # violar NOT NULL no record_phase.
  def fase_a_error(type)
    { status: 'error', error_type: type, tokens_in: 0, tokens_out: 0, cached_tokens: 0, cost: 0.0, latency_ms: 0, decision: {} }
  end

  # single: schema + tools na MESMA chamada (caminho OpenAI confirmado; o provider conduz o loop de tools).
  def run_fase_a_single(system_prompt, native)
    Ai::ModelRouter.decide(profile: @agent.operation_profile, system_prompt: system_prompt,
                           user_message: context_builder.user_message(@sp_content), account_id: @account.id,
                           json: true, temperature: 0.2, schema: Ai::DecisionSchema.without_reply_text, tools: native)
  end

  # a1a2 (flag interno de reserva): A1 tools SEM schema (busca dados; texto ignorado, reads no coletor) ->
  # A2 schema SEM tools, com os reads apurados no prompt. Soma o custo de A1 na run de decisão.
  def run_fase_a1a2(run_record, decision_prompt, native)
    a1 = Ai::ModelRouter.generate_text(profile: @agent.operation_profile, system_prompt: fase_a1_prompt,
                                       user_message: context_builder.user_message(@sp_content),
                                       account_id: @account.id, temperature: 0.2, tools: native)
    emit(run_record, 'split.fase_a1', { chars: a1[:text].to_s.length, cost: a1[:cost], reads: @sp_reads.size })
    a2_prompt = @sp_reads.present? ? "#{decision_prompt}\n\nDados já apurados pelas ferramentas:\n#{@sp_reads.join("\n---\n")}" : decision_prompt
    a2 = Ai::ModelRouter.decide(profile: @agent.operation_profile, system_prompt: a2_prompt,
                                user_message: context_builder.user_message(@sp_content), account_id: @account.id,
                                json: true, temperature: 0.2, schema: Ai::DecisionSchema.without_reply_text, tools: nil)
    merge_phase_cost(a2, a1)
  end

  def fase_a1_prompt
    'Você é um assistente de PESQUISA interno. Use as ferramentas disponíveis para buscar os dados que o ' \
      'cliente pediu (catálogo/conhecimento). NÃO responda ao cliente; apenas colete as informações.'
  end

  def merge_phase_cost(primary, extra)
    primary.merge(
      tokens_in: primary[:tokens_in].to_i + extra[:tokens_in].to_i,
      tokens_out: primary[:tokens_out].to_i + extra[:tokens_out].to_i,
      cached_tokens: primary[:cached_tokens].to_i + extra[:cached_tokens].to_i,
      cost: primary[:cost].to_f + extra[:cost].to_f,
      latency_ms: primary[:latency_ms].to_i + extra[:latency_ms].to_i
    )
  end

  # FASE B — resposta ao cliente (run 'reply' própria) com persona + reads + estado; TEXTO puro. temperature
  # nil = slider do perfil; 0.2 no handoff. Falha/vazio -> reply seguro do playbook (nunca vaza JSON).
  def run_fase_b(run_record, department, extra_instruction: nil, temperature: nil)
    reply_run = Ai::Run.create!(account_id: @account.id, conversation_id: @conversation.id, ai_agent_id: @agent.id,
                                inbox_id: @message.inbox_id, run_type: 'reply', mode: @mode, status: 'running')
    prompt = Ai::PromptCompiler.reply_prompt(agent: @agent, department: department, reads: @sp_reads,
                                             collected: @sp_collected, memory: @sp_memory,
                                             customer_memory: @sp_customer_memory, step_index: @sp_step_index)
    prompt = "#{prompt}\n\n#{extra_instruction}" if extra_instruction.present?
    res = Ai::ModelRouter.generate_text(profile: @agent.operation_profile, system_prompt: prompt,
                                        user_message: context_builder.user_message(@sp_content),
                                        account_id: @account.id, temperature: temperature)
    record_phase(reply_run, res, 'reply')
    emit(reply_run, 'reply.generated',
         { chars: res[:text].to_s.length, cost: res[:cost], cached_tokens: res[:cached_tokens], temperature: res[:temperature] },
         run_id: reply_run.id)
    return safe_playbook_reply(department) if res[:status] == 'error' || res[:text].to_s.strip.empty?

    res[:text].to_s.strip
  rescue StandardError => e
    Rails.logger.error "[Ai::Gateway#run_fase_b] #{e.class}: #{e.message}"
    safe_playbook_reply(department)
  end

  def dispatch_split_reply(run_record, department)
    text = run_fase_b(run_record, department)
    return if text.blank?

    guard = Ai::LoopGuard.new(conversation: @conversation, current_run: run_record)
    if guard.loop?(text)
      emit(run_record, 'reply.loop_detected', { chars: text.length })
      force_loop_handoff(run_record)
    else
      action_dispatcher.reply(department, text)
    end
  end

  def dispatch_split_close(run_record, department)
    msg = department.close_rules.to_h['message'].presence
    text = msg || run_fase_b(run_record, department,
                             extra_instruction: 'O cliente está encerrando o atendimento. Escreva uma DESPEDIDA curta e cordial.')
    action_dispatcher.reply(department, text) if text.present?
    action_dispatcher.execute_action('conversation.resolve', {}, run_record, 'close')
  end

  def dispatch_split_handoff(run_record, department, decision, handoff)
    return if handoff_coordinator.route_to_ai(decision)

    retrying = @conversation.additional_attributes&.dig('ai_handoff').present? && @conversation.assignee_id.blank?
    unless retrying
      text = handoff_transition_text(run_record, department)
      action_dispatcher.reply(department, text) if text.present?
    end
    team_id = handoff_coordinator.human_team_id(decision)
    input = { 'unassign' => true }
    input['team_id'] = team_id if team_id
    action_dispatcher.execute_action('conversation.transfer', input, run_record, 'handoff', extra: { reason: handoff[:reason], team_id: team_id })
    handoff_coordinator.assign_human(team_id, reason: handoff[:reason])
  end

  # Handoff NÃO usa temperatura de slider: mensagem configurada (transfer_rules['message']) OU gerada em
  # TEMPERATURA BAIXA (0.2). Handoff não é hora de variação criativa.
  def handoff_transition_text(run_record, department)
    configured = department.transfer_rules.to_h['message'].presence
    return configured if configured

    text = run_fase_b(run_record, department,
                      extra_instruction: 'Escreva UMA linha curta avisando que vai transferir para um atendente humano.',
                      temperature: 0.2)
    text.presence || 'Vou te transferir para um especialista do nosso time, tá? 😊'
  end

  def safe_playbook_reply(department)
    (department.playbook&.default_messages || {})['greeting'].presence || 'Certo! Já te respondo. 🙂'
  end

  # Executa a tool de AÇÃO (department) via ToolExecutor — igual ao fluxo único. Tools de LEITURA são as
  # nativas (with_tools na Fase A), não passam por aqui. Nome desconhecido -> ignora (nil).
  def execute_action_tool(run_record, department, intended_tool)
    return nil if intended_tool.blank?

    tool = department.tools.active.find_by(name: intended_tool['name'])
    return nil unless tool

    execution = Ai::ToolExecutor.new(tool: tool, input: intended_tool['input'], conversation: @conversation,
                                     mode: @mode, run: run_record).perform
    emit(run_record, 'tool.executed', { tool: tool.name, status: execution.status, execution_id: execution.id })
    execution
  rescue StandardError => e
    Rails.logger.error "[Ai::Gateway#execute_action_tool] #{e.class}: #{e.message}"
    nil
  end

  # Tools nativas de LEITURA instanciadas com o contexto do turno + callback de auditoria. Só usadas na
  # Fase A ao vivo (split só roda live). reads é acumulado para a Fase B.
  def native_read_tools(run_record)
    cb = reader_callback(run_record)
    [Ai::Tools::ListaCatalogo.new(account_id: @account.id, department_id: @sp_department.id, on_read: cb),
     Ai::Tools::BuscaConhecimento.new(account_id: @account.id, department_id: @sp_department.id, on_read: cb)]
  end

  def reader_callback(run_record)
    reads = @sp_reads
    lambda do |tool_name, args, chunks|
      reads.concat(Array(chunks))
      audit_native_read(run_record, tool_name, args, chunks)
    end
  end

  def audit_native_read(run_record, tool_name, args, chunks)
    Ai::CapabilityExecution.create!(
      account_id: @account.id, conversation_id: @conversation.id, ai_tool_id: nil, ai_run_id: run_record.id,
      capability_key: "native_read:#{tool_name}", input: args, output: { 'chunks' => Array(chunks).size },
      status: 'executed', governance: 'allowed', approval_status: 'not_required', requested_by: 'ai'
    )
    emit(run_record, 'tool.native_read', { tool: tool_name, args: args, chunks: Array(chunks).size })
  rescue StandardError => e
    Rails.logger.error "[Ai::Gateway#audit_native_read] #{e.class}: #{e.message}"
  end

  def record_phase(run, result, _kind)
    run.update!(
      provider: result[:provider], model: result[:model], tokens_in: result[:tokens_in],
      tokens_out: result[:tokens_out], cached_tokens: result[:cached_tokens], cost: result[:cost],
      latency_ms: result[:latency_ms], decision: result[:decision] || {},
      status: (result[:status] == 'error' ? 'error' : 'recorded'),
      error_type: (result[:status] == 'error' ? 'provider_error' : nil)
    )
  rescue StandardError => e
    Rails.logger.error "[Ai::Gateway#record_phase] #{e.class}: #{e.message}"
  end

  # Fallback (Fase A falhou): fluxo ÚNICO antigo (full compile + decide com reply_text + tool_followup +
  # dispatch). Reusa a run de decisão já criada. Nunca vaza JSON (guard/rede #unparsed preservadas).
  def run_single_fallback(run_record, department, effective_content)
    @stage = :knowledge
    knowledge = Ai::KnowledgeRetriever.retrieve(query: effective_content, account_id: @account.id, department_id: department.id)
    system_prompt = Ai::PromptCompiler.compile(
      agent: @agent, department: department, knowledge: knowledge, memory: @sp_memory, tools: @sp_action_tools,
      collected: @sp_collected, fillable_attributes: context_builder.fillable_attributes(department),
      customer_memory: @sp_customer_memory, step_index: @sp_step_index
    )
    result = Ai::ModelRouter.decide(profile: @agent.operation_profile, system_prompt: system_prompt,
                                    user_message: context_builder.user_message(effective_content), account_id: @account.id, json: true)
    record_phase(run_record, result, 'decision')
    emit(run_record, 'decision.made', { decision: result[:decision], phase: 'fallback', cost: result[:cost], cached_tokens: result[:cached_tokens] }, run_id: run_record.id)

    state_manager.track_step(department, result[:decision] || {}, dispatcher: action_dispatcher, run: run_record,
                                                                  message_text: effective_content, message: @message)
    state_manager.persist_attributes((result[:decision] || {})['attributes'], department, source: :supervisor)

    intended_tool = result.dig(:decision, 'tool')
    execution = execute_action_tool(run_record, department, intended_tool)
    if intended_tool.present? && execution&.status == 'executed'
      fp = Ai::PromptCompiler.compile(agent: @agent, department: department, knowledge: knowledge, memory: @sp_memory,
                                      tools: [], customer_memory: @sp_customer_memory, followup: true,
                                      collected: @sp_collected, step_index: @sp_step_index)
      result = tool_followup(run_record, fp, effective_content, intended_tool, execution)
    end

    dispatch_fallback(run_record, department, result, system_prompt, effective_content, intended_tool)
    state_manager.update_memory
    finalize(run_record, result[:status] == 'error' ? 'error' : 'recorded')
  end

  def dispatch_fallback(run_record, department, result, system_prompt, effective_content, intended_tool)
    decision_kind = (result[:decision] || {})['decision']
    handoff = Ai::HandoffEvaluator.evaluate(decision: result[:decision] || {}, department: department)
    if handoff[:handoff]
      dispatch_split_handoff(run_record, department, result[:decision] || {}, handoff) # reusa transfer+assign
    elsif decision_kind == 'close'
      farewell = close_farewell(department, result[:decision] || {})
      action_dispatcher.reply(department, farewell) if farewell.present?
      action_dispatcher.execute_action('conversation.resolve', {}, run_record, 'close')
    elsif decision_kind == 'reply' || intended_tool.present?
      safe = guard_against_loop(run_record, system_prompt, effective_content, (result[:decision] || {})['reply_text'])
      action_dispatcher.reply(department, safe) if safe
    end
  end

  def finalize(run_record, status)
    run_record.update!(status: status)
    run_record
  end

  def emit(run_record, type, payload, run_id: nil)
    Ai::Event.create!(
      account_id: @account.id, conversation_id: @conversation.id,
      ai_run_id: run_id, event_type: type, payload: payload, status: 'ok'
    )
  end
end
