# The AI Gateway — F1 happy-path, SHADOW only.
# Pipeline: message.received -> resolve_agent (caller) -> resolve_department -> assemble_context
#           -> retrieve_knowledge -> decide -> record ai_runs + ai_events.
# In shadow it NEVER replies, NEVER executes a tool, NEVER writes operational changes — it only
# records intention, runs and events.
class Ai::Gateway
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

    @stage = :knowledge
    knowledge = Ai::KnowledgeRetriever.retrieve(query: effective_content, account_id: @account.id, department_id: department.id)
    emit(run_record, 'knowledge.retrieved', { count: knowledge.size, preview: knowledge.first(2) })
    run_record.update!(knowledge_count: knowledge.size)

    memory = Ai::AgentMemory.find_by(conversation_id: @conversation.id, ai_agent_id: @agent.id)
    customer_memory = @conversation.contact_id &&
                      Ai::CustomerMemory.find_by(contact_id: @conversation.contact_id, account_id: @account.id)
    tools  = department.tools.active.to_a
    @stage = :context
    system_prompt = Ai::PromptCompiler.compile(
      agent: @agent, department: department, knowledge: knowledge, memory: memory, tools: tools,
      collected: (@conversation.contact&.custom_attributes || {})
        .merge(@conversation.custom_attributes || {}),
      fillable_attributes: context_builder.fillable_attributes(department),
      customer_memory: customer_memory
    )
    emit(run_record, 'context.assembled', { prompt_chars: system_prompt.length, tools: tools.map(&:name) })

    @stage = :decision
    result = Ai::ModelRouter.decide(
      profile: @agent.operation_profile, system_prompt: system_prompt,
      user_message: context_builder.user_message(effective_content), account_id: @account.id, json: true
    )
    run_record.update!(
      provider: result[:provider], model: result[:model],
      tokens_in: result[:tokens_in], tokens_out: result[:tokens_out],
      cost: result[:cost], latency_ms: result[:latency_ms],
      decision: result[:decision] || {}, status: result[:status],
      error_type: (result[:status] == 'error' ? 'provider_error' : nil)
    )
    emit(run_record, 'decision.made',
         { decision: result[:decision], cost: result[:cost], latency_ms: result[:latency_ms], temperature: result[:temperature] },
         run_id: run_record.id)

    # Track which step the conversation is on so message grouping can use that step's delay; also
    # fires the step's completion automations when the model signals step_completed (audited actions
    # reuse this run's dispatcher). track_step swallows its own errors — never breaks the Gateway.
    state_manager.track_step(department, result[:decision] || {}, dispatcher: action_dispatcher, run: run_record) if @acts_live
    # Grava os dados coletados (cidade, plano, etc.) nos atributos da conversa, conforme o modelo
    # devolveu em `attributes`. Assim os campos vão sendo alimentados e reaproveitados (não repergunta).
    state_manager.persist_attributes((result[:decision] || {})['attributes']) if @acts_live

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
      result = tool_followup(run_record, system_prompt, effective_content, intended_tool, execution)
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
      decision: result[:decision] || {}, department: department, message_content: effective_content
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
        # para a IA atender primeiro; aqui é o único ponto que entrega a um agente.
        handoff_coordinator.assign_human(team_id) if @acts_live
      end
    elsif decision_kind == 'close'
      action_dispatcher.execute_action('conversation.resolve', {}, run_record, 'close')
    elsif decision_kind == 'reply'
      safe_reply = guard_against_loop(run_record, system_prompt, effective_content,
                                      (result[:decision] || {})['reply_text'])
      action_dispatcher.reply(department, safe_reply) if safe_reply
    elsif intended_tool.present? && @acts_live
      # Safety net: a tool ran but the follow-up decision still isn't a plain reply/close/handoff —
      # send whatever text we have so the customer is never left waiting after a tool call.
      action_dispatcher.reply(department, (result[:decision] || {})['reply_text'])
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
         { decision: result[:decision], cost: result[:cost], latency_ms: result[:latency_ms] })
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
    handoff_coordinator.assign_human(team_id)
    emit(run_record, 'handoff.loop_forced', { team_id: team_id })
  rescue StandardError => e
    Rails.logger.error "[Ai::Gateway#force_loop_handoff] #{e.class}: #{e.message}"
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
    handoff_coordinator.assign_human(team_id)
    emit(run_record, 'handoff.credit_exhausted', { team_id: team_id })
  rescue StandardError => e
    Rails.logger.error "[Ai::Gateway#force_credit_handoff] #{e.class}: #{e.message}"
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
