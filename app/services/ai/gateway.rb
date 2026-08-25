# The AI Gateway. Pipeline: message.received -> gates (billing/breaker/trivial) ->
# Ai::PythonOrchestratorClient (o único motor — vê knowledge/tools/decisão por conta própria) ->
# record ai_runs + ai_events -> reply.
# In shadow it NEVER replies, NEVER executes a tool, NEVER writes operational changes — it only
# records intention, runs and events.
class Ai::Gateway
  # Fase 2: janela do e-mail ao admin quando um erro de provedor vira handoff. 1h por (conta, provedor) —
  # maior que os 15 min do handoff-sem-agente de propósito: cota estourada é condição sustentada, o admin
  # quer UM aviso e não dezenas. Ver #notify_admin_provider_error.
  PROVIDER_ERROR_NOTIFY_TTL = 1.hour
  # Achado ao vivo (18/08): o campo "Orçamento" (Perfis de Operação) salvava monthly_usd/on_limit mas
  # nada no backend lia — um admin configurava um teto que não fazia NADA. 1 aviso/dia por perfil (não
  # por chamada): estourar o orçamento é condição SUSTENTADA o mês inteiro, não um evento pontual — ver
  # #notify_admin_budget_exceeded.
  BUDGET_NOTIFY_TTL = 1.day

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

    base_content = @content_override.presence || @message.content

    @stage = :persist
    # Teto configurável por TIPO de anexo (áudio em segundos, documento em caracteres — ver
    # Ai::Workers::MediaProcessor#oversized_attachment_type pro porquê de cada unidade e por que imagem
    # não entra aqui). Achado ao vivo (21/08): só existia teto pra TEXTO (max_input_chars); um anexo
    # gigante contornava o limite de caracteres inteiro (ia direto pra visão nativa ou era parseado por
    # completo antes de qualquer corte). oversized_kind vira o file_type recusado ('audio'/'file');
    # skip_types evita reprocessar esse anexo em #process (o reply de recusa acontece mais abaixo,
    # DEPOIS dos gates de credit/budget/max_replies/stuck_turns — mesmo lugar/prioridade do ask_resume
    # de texto).
    oversized_kind = Ai::Workers::MediaProcessor.oversized_attachment_type(
      @message, @account.id, @agent.operation_profile, @conversation.id, attachment_limits
    )
    # Invisible worker: turn media (audio/image/PDF escaneado) into text the supervisor can use. Passa
    # o profile do agente para o OCR ler o worker de visão configurado (worker_overrides['ocr']).
    # skip_vision SEMPRE true — a OpenAI já recebe os pixels crus (Ai::PythonOrchestratorClient#image_urls:
    # foto direta E/OU páginas rasterizadas de PDF escaneado) e enxerga nativamente no MESMO turno, sem
    # o motor legado pra usar a legenda do OCR como fallback; áudio/docx/vídeo continuam passando por aqui
    # (sem equivalente nativo no Python ainda).
    media_text = Ai::Workers::MediaProcessor.process(@message, @agent.operation_profile, skip_vision: true,
                                                      skip_types: Array(oversized_kind))
    emit(run_record, 'media.preprocessed', { text: media_text }) if media_text.present?
    effective_content = [base_content, media_text].compact.join("\n").strip

    # Config do agente + gate de política (reply state) + caminho ask_resume — nada disso é
    # classificação; erro aqui é 'internal_error', não 'classification_failed'.
    @stage = :policy
    # Limite de caracteres da mensagem do cliente (anti-abuso/tokens). Ação configurável:
    # 'truncate' (padrão: corta nos N primeiros) ou 'ask_resume' (pede pro cliente resumir e
    # NÃO processa o texto gigante). Tratado abaixo, após o gate de resposta.
    max_input = @agent.behavior.to_h['max_input_chars'].to_i
    input_action = @agent.behavior.to_h['max_input_action'].presence || 'truncate'
    input_exceeded = max_input.positive? && effective_content.length > max_input
    effective_content = effective_content.first(max_input) if input_exceeded && input_action != 'ask_resume'

    # Single gate for every outward action (reply, tools, transfer/resolve): the AI only acts when
    # this conversation is effectively live — i.e. live binding + auto_attendance on + within hours
    # + reply_scope all/canary-match. Otherwise it observes (records intention) only, so a live
    # binding piloted "behind canary" never touches non-canary conversations.
    @acts_live =
      Ai::ReplyPolicy.effective_reply_state(mode: @mode, agent: @agent, conversation: @conversation) == :live

    # Billing Fase 2: aviso proativo de saldo baixo (90% usado) + bloqueio ao ESGOTAR. Só ao vivo p/
    # o bloqueio; conta sem balance/plano ou com chave própria (custom_llm_api_key) = LIBERA
    # (fail-open). Ao esgotar, entrega ao humano com nota interna e NÃO roda o modelo (zero custo).
    maybe_notify_low_balance(run_record)
    if @acts_live && credit_exhausted?
      force_credit_handoff(run_record)
      return finalize(run_record, 'credit_exhausted')
    end

    # Orçamento do PERFIL (Ai::OperationProfile#budget_exceeded?, teto mensal somado entre todos os
    # agentes que reusam o mesmo perfil — ver o model). "stop": mesmo padrão pré-chamada de
    # credit_exhausted? acima, zero custo LLM, handoff pra humano. "alert": só avisa e SEGUE normal —
    # a IA continua respondendo, o teto é só visibilidade. "downgrade": ainda não existe um modelo
    # mais barato definido pra trocar — tratado como "alert" por ora (ver comentário em
    # Ai::OperationProfile#budget_on_limit); documentado, não escondido.
    if @acts_live && @agent.operation_profile&.budget_exceeded?
      if @agent.operation_profile.budget_on_limit == 'stop'
        force_budget_handoff(run_record)
        return finalize(run_record, 'budget_exceeded')
      else
        notify_admin_budget_exceeded(stopped: false)
      end
    end

    # Teto de respostas da IA (max_replies): ao atingir o limite configurado no agente, a IA
    # para de responder e TRANSFERE para humano — mesmo fluxo do force_credit_handoff (nota interna +
    # transfer + assign, sem mensagem ao cliente). Verifica antes de rodar o modelo (zero custo LLM).
    if @acts_live && max_replies_reached?
      force_max_replies_handoff(run_record)
      return finalize(run_record, 'max_replies')
    end

    # stuck_handoff_turns (tela de Etapas — "Transferir para humano se travar em uma etapa por X
    # mensagens"): achado ao vivo (13/08, relacionado ao ticket 557) — até aqui isso era só um empurrão
    # de PROMPT (force_handoff_notice/force_handoff_instruction, mais abaixo) pedindo pro modelo
    # transferir; nada IMPEDIA o modelo de ignorar e continuar enrolando. Vira bloqueio de verdade: ao
    # atingir o teto, o Gateway transfere direto, mesmo padrão pré-chamada de credit_exhausted?/
    # max_replies_reached? acima (zero custo LLM). O empurrão de prompt continua existindo (não foi
    # tocado, sem refatorar) — na prática dá 1 turno de graça pro modelo se corrigir sozinho antes
    # deste bloqueio pegar no turno seguinte, já que ai_step_turns só reflete o valor ATÉ o turno
    # anterior aqui. NÃO ressuscita Ai::StateManager/StepResolver/TurnCapture (Gap 1-4) — checagem
    # nova e isolada, reusando step_turns_exceeded? que já existia pro empurrão de prompt.
    if @acts_live && step_turns_exceeded?
      force_stuck_step_handoff(run_record)
      return finalize(run_record, 'stuck_handoff')
    end

    # Fase 3 — circuit breaker por (conta, provider). Com o breaker ABERTO, PULA todo o caminho condenado
    # (RAG + montagem de contexto + chamada ao modelo) e vai direto ao handoff da Fase 1 — MESMO padrão
    # pré-chamada do credit_exhausted? acima, custo e latência ZERO. Só ao vivo (shadow nunca transfere nem
    # mexe no breaker). :half_open = passe de teste concedido a ESTE run (segue o fluxo normal; a chamada lá
    # embaixo fecha/reabre via record_success/record_failure). notify:false no skip — o e-mail já saiu na
    # ABERTURA (a 3ª falha, throttle de 1h); com o breaker já aberto NÃO reenvia. Ver Ai::ProviderBreaker.
    if @acts_live
      case provider_breaker.state
      when :open
        run_record.update!(provider: supervisor_provider, status: 'error', error_type: 'provider_error')
        emit(run_record, 'provider.breaker_skipped', { provider: supervisor_provider, open_until: provider_breaker.open_until })
        force_provider_handoff(run_record, notify: false)
        return finalize(run_record, 'error')
      when :half_open
        emit(run_record, 'provider.breaker_half_open', { provider: supervisor_provider })
      end
    end

    # Mensagem acima do limite + ação "pedir resumo": avisa o cliente e encerra a execução
    # (não roda o modelo no texto gigante). 'truncate' segue normal (já cortado acima).
    if input_exceeded && input_action == 'ask_resume'
      message = @agent.behavior.to_h['max_input_message'].presence ||
                'Sua mensagem ficou longa demais para eu entender bem. Pode resumir em poucas linhas, por favor? 🙂'
      emit(run_record, 'input.too_long', { chars: effective_content.length, max: max_input })
      action_dispatcher.reply(message)
      return finalize(run_record, 'input_too_long')
    end

    # Anexo (imagem/documento/áudio) acima do teto do seu tipo: já não foi processado (skip_types
    # acima) — avisa o cliente com a mensagem configurada pro tipo e encerra, sem chamar o modelo.
    if oversized_kind
      emit(run_record, 'attachment.too_large', { kind: oversized_kind })
      action_dispatcher.reply(oversized_attachment_message(oversized_kind))
      return finalize(run_record, 'attachment_too_large')
    end

    # active_step ainda alimenta a Camada 0 (triagem de turno trivial) abaixo — o resto do que dependia
    # dele (conhecimento sob demanda, resolve_knowledge/next_step) saiu junto do motor legado; o Python
    # busca conhecimento por conta própria (Ai::PythonOrchestratorClient).
    active_step = @acts_live ? state_manager.current_step(@agent) : nil

    # Camada 0 — triagem de turno trivial (opt-in, default OFF). ANTES de qualquer chamada ao modelo:
    # um turno trivial ("ok"/"obrigada"/emoji solto em reação à nossa última msg) NÃO acorda o supervisor.
    # Gate determinístico (regex + estado local), custo ZERO. Silêncio é o comportamento v1 DECIDIDO
    # (responder "de nada" convidaria outro "obrigada" — loop de cortesia). Vale live E shadow (em shadow
    # também economiza a chamada; sem efeito colateral). OFF => byte-idêntico ao fluxo atual.
    # active_step é nil em shadow por design, então resolvemos a etapa REAL aqui p/ a condição c valer nos
    # dois modos (na dúvida, NÃO pula). Ver Ai::TrivialTurnGate.
    if trivial_gate_on?
      gate = Ai::TrivialTurnGate.skip?(text: effective_content, conversation: @conversation,
                                       step: active_step || state_manager.current_step(@agent),
                                       conclude_ready: state_manager.conclude_ready_for_current?(@agent))
      if gate[:skip]
        run_record.update!(run_type: 'trivial_skip', tokens_in: 0, tokens_out: 0, cost: 0)
        emit(run_record, 'turn.trivial_skipped', { reason: gate[:reason] })
        return finalize(run_record, 'recorded')
      end
    end

    # Python é o ÚNICO motor: substitui knowledge retrieval + Ai::PromptCompiler + Ai::ContextBuilder +
    # Ai::ModelRouter por completo — o Python possui o loop de raciocínio/tool-call da Responses API
    # (tools nativas resolvidas no Python; tools do lado Rails via Api::Internal::AiExecuteToolController).
    # O Gateway ainda roda os gates acima (billing/breaker/trivial) e ainda entrega via action_dispatcher
    # abaixo. Roda nos DOIS modos — shadow também registra uma decisão para avaliação; o próprio gate de
    # modo do Ai::ToolExecutor (não este branch) é o que impede o shadow de agir.
    @stage = :decision
    # Teto de segurança por etapa (ai_step_turns), lido ANTES de chamar o Python — Rails é o
    # guarda-fio da contagem, a IA só interpreta texto. Se já estourou o limite configurado na tela
    # (transfer_rules['stuck_handoff_turns'], mesma chave do caminho legado), o client injeta uma
    # instrução forçada no turno para a IA transferir AGORA via a tool conversation.transfer.
    step_index_before = (@conversation.additional_attributes || {})['ai_step_index'].to_i
    force_handoff_notice = step_turns_exceeded?

    result = Ai::PythonOrchestratorClient.process_message(
      conversation: @conversation, content: effective_content, agent: @agent, mode: @mode,
      message: @message, force_handoff_notice: force_handoff_notice
    )
    persist_openai_conversation_id(result[:conversation_id]) if result[:conversation_id].present?
    # BYOK (billing Fase 3): o Python já fez o retry internamente (ver orchestrator.py) — aqui só
    # espelha o que #maybe_byok_fallback fazia no caminho legado: tag de visibilidade + cobra 1
    # crédito SCNET pela chamada que teve que usar a chave global. Só ao vivo (shadow não gasta).
    if @acts_live && result[:byok_fallback]
      apply_label('chave-propria-falhou')
      emit(run_record, 'decision.byok_fallback', { provider: 'openai' })
      consume_byok_fallback_credit
    end
    # "avancar_etapa" (chamado mid-loop pelo Python, via Api::Internal::AiExecuteToolController) já
    # zerou ai_step_turns se a etapa avançou; senão este turno não produziu avanço -> soma 1.
    bump_step_turns_unless_advanced(step_index_before) if @acts_live
    status = result[:reply].present? ? 'recorded' : 'error'
    # Achado ao vivo (18/08): a tela "Análises com IA" (Api::V1::Accounts::AiShadowRunsController) lê
    # decision['decision']/['reply_text']/['confidence'] — chaves do CONTRATO ANTIGO
    # (Ai::ModelRouter.decide, motor Ruby legado). Este branch (Python, único motor hoje) gravava
    # 'kind'/'text', que NENHUM consumidor lê (confirmado por grep) — resultado: 100% dos turnos reais
    # caíam no fallback 'unanswered' do classify() da tela, mesmo turnos respondidos/com confiança
    # normal, e "Lacunas de conhecimento" ficava inflado (não dá pra distinguir "respondeu" de "não
    # respondeu" quando os dois viram a mesma string). decision => 'handoff' quando o PRÓPRIO modelo
    # decidiu transferir neste turno (result[:transferred], TRANSFER_TOOL já disparou mid-turn antes
    # daqui) — sem isso esses turnos TAMBÉM cairiam em 'unanswered'. 'tool'/knowledge_count continuam
    # sem sinal (orchestrator.py não devolve isso pro Rails hoje — ver
    # docs/ai-shadow-analysis-module-assessment.md §5, fora do escopo deste fix).
    # Custo real (achado ao vivo, 20/08): antes desta chamada, model/tokens_in/tokens_out ficavam
    # SEMPRE ausentes aqui — Ai::PythonOrchestratorClient não trazia usage nenhum do Python, então
    # TODO run deste motor tinha custo zerado na tela "Custos de IA" (Api::V1::Accounts::
    # AiCostsController), mesmo a conta sendo cobrada de verdade pela OpenAI — e o orçamento do perfil
    # (Ai::OperationProfile#budget_exceeded?, que soma Ai::Run.cost) nunca disparava de verdade por
    # causa do mesmo buraco. billed_model é o que REALMENTE rodou (Ai::PythonOrchestratorClient
    # devolve o valor após o fallback do orchestrator.py, pode divergir do supervisor_model do perfil).
    billed_model = result[:model].presence || supervisor_model
    run_record.update!(provider: 'openai', model: billed_model,
                        tokens_in: result[:tokens_in].to_i, tokens_out: result[:tokens_out].to_i,
                        cost: Ai::ModelRouter.estimate_cost(billed_model, result[:tokens_in], result[:tokens_out]),
                        decision: { 'decision' => (result[:transferred] ? 'handoff' : 'reply'),
                                    'reply_text' => result[:reply], 'confidence' => result[:confidence],
                                    # Quebra por ferramenta chamada (pedido da aba Teste, 21/08) — só lida
                                    # hoje por Api::V1::Accounts::AiAgentTestConversationsController;
                                    # nenhum consumidor existente lê esta chave, então é segura de adicionar.
                                    'tool_calls' => result[:tool_calls] },
                        status: status, error_type: (status == 'error' ? 'provider_error' : nil))
    emit(run_record, 'decision.made', { decision: { 'kind' => 'reply' }, source: 'python_orchestrator' }, run_id: run_record.id)

    # Fase 3 — alimenta o breaker com o RESULTADO desta chamada (só ao vivo): erro incrementa as falhas
    # consecutivas (abre na 3ª ou reabre um half-open); sucesso zera e fecha. Mesmo padrão do antigo
    # caminho decide() — sem isto o breaker nunca mais recebe sinal algum (a chamada legada era a única
    # fonte) e o gate de "breaker aberto" acima nunca teria motivo pra abrir.
    if @acts_live
      if status == 'error'
        opened = provider_breaker.record_failure
        emit(run_record, 'provider.breaker_opened', { provider: 'openai' }.merge(opened)) if opened
      elsif (closed_via = provider_breaker.record_success)
        emit(run_record, 'provider.breaker_closed', { provider: 'openai', via: closed_via })
      end
    end

    # Provider indisponível (HTTP/timeout/exceção no client, ou reply vazio): sem esta guarda,
    # Ai::PythonOrchestratorClient#perform já devolve reply: nil e action_dispatcher.reply(nil)
    # é um no-op silencioso (text.blank? => return) — o cliente ficava sem resposta E sem handoff. Espelha
    # o force_provider_handoff do antigo caminho decide(). Só ao vivo; em shadow apenas registra o erro.
    if @acts_live && status == 'error'
      force_provider_handoff(run_record)
      return finalize(run_record, 'error')
    end

    # DÉBITO ACEITO (temporário, não esquecimento): Ai::LoopGuard (detecção de repergunta/paráfrase em
    # loop + retry com nudge + handoff forçado) NÃO tem equivalente no caminho Python — nunca teve,
    # mesmo quando a flag python_orchestrator estava ligada só para alguns departments. Antes disso era
    # um risco isolado (só quem tinha a flag); com a eliminação do motor legado (este commit), o alcance
    # vira 100% da base — TODO department fica sem essa rede de segurança. Decisão consciente de NÃO
    # bloquear a eliminação por isso (ver conversa da eliminação do motor legado). Tarefa de fechamento
    # rastreada separadamente — ver memória do projeto (loopguard-python-parity-debt) — não implementar
    # aqui como parte deste commit.
    # Confiança baixa (Ai::HandoffEvaluator, agent.transfer_rules['min_confidence']) — migrado pro
    # motor Python (orchestrator.CONFIANCA_KEY, 17/08): o campo existia na tela desde o motor legado mas
    # nunca teve efeito nenhum no caminho Python (achado nesta mesma investigação). O modelo AUTO-RELATA
    # confiança 0.0-1.0 a cada turno, DEPOIS de já ter rodado tools/salvado dados/decidido reply vs
    # handoff — só verifica quando o PRÓPRIO modelo não decidiu transferir (result[:transferred]); se já
    # decidiu, o handoff já rodou via o webhook TRANSFER_TOOL que o Python disparou mid-turn, e chamar
    # de novo aqui duplicaria a transferência. Silencioso, mesmo padrão de force_max_replies_handoff/
    # force_stuck_step_handoff: NÃO manda result[:reply] ao cliente (pode ser a própria resposta de
    # baixa confiança, ex.: o bug real do Pinhalzinho — "Atendemos sua cidade!" sem fonte nenhuma) — um
    # humano assume a partir daqui.
    if @acts_live && !result[:transferred] && low_confidence?(result[:confidence])
      force_low_confidence_handoff(run_record, result[:confidence])
      return finalize(run_record, 'low_confidence')
    end

    # bypass_handoff: @acts_live foi decidido ANTES de chamar o Python (linha ~84), com o estado PRÉ-
    # turno da conversa. Se já era live ali, um handoff/atribuição que ESTE MESMO turno acabou de fazer
    # (transferir_humano/on_complete handoff_human, via a request HTTP separada do
    # Api::Internal::AiExecuteToolController, cujo write o @conversation.reload acima de
    # bump_step_turns_unless_advanced acabou de trazer) não pode engolir a mensagem que o próprio
    # modelo compôs pra avisar da transferência. Achado ao vivo (15/08, ticket 583): "reply.intended"
    # em vez de "reply.sent" — cliente nunca recebeu o aviso, apesar do handoff ter executado certinho.
    action_dispatcher.reply(result[:reply], bypass_handoff: @acts_live)
    finalize(run_record, status)
  rescue StandardError => e
    error_type = classify_error(e)
    # Loga a etapa e a categoria junto do erro — o "porquê" fica no log; o "o quê" (agregável) na run.
    Rails.logger.error "[Ai::Gateway] ticket_id=#{@conversation&.id} stage=#{@stage} type=#{error_type} #{e.class}: #{e.message}"
    run_record.update!(status: 'error', error_type: error_type) if defined?(run_record) && run_record&.persisted?
    nil
  end

  private

  # Camada 0 ligada? Opt-in por perfil no MESMO padrão aninhado dos demais workers
  # (worker_overrides['trivial_gate']['mode'] == 'on'). Ausente/qualquer outro valor => OFF (default),
  # e o fluxo fica byte-idêntico ao atual.
  def trivial_gate_on?
    @agent.operation_profile&.worker('trivial_gate')&.dig('mode').to_s == 'on'
  end

  # Mesma chave/default do caminho legado (Ai::StateManager#stuck_handoff_limit) — teto ausente =>
  # DEFAULT_STUCK_HANDOFF_TURNS (rede ligada por padrão); 0 = desligado.
  def step_turns_exceeded?
    limit = @agent.transfer_rules.to_h.key?('stuck_handoff_turns') ? @agent.transfer_rules['stuck_handoff_turns'].to_i : Ai::StateManager::DEFAULT_STUCK_HANDOFF_TURNS
    return false unless limit.positive?

    (@conversation.additional_attributes || {})['ai_step_turns'].to_i >= limit
  end

  # +1 turno "parado" na etapa, A MENOS que este turno tenha avançado (a tool "avancar_etapa",
  # executada por um processo separado — Api::Internal::AiExecuteToolController, chamado pelo Python
  # mid-loop — já zerou ai_step_turns nesse caso). Reload obrigatório: esse avanço acontece numa
  # request HTTP própria, commitada num objeto Conversation diferente deste em memória.
  def bump_step_turns_unless_advanced(step_index_before)
    @conversation.reload
    attrs = @conversation.additional_attributes || {}
    return if attrs['ai_step_index'].to_i != step_index_before

    attrs['ai_step_turns'] = attrs['ai_step_turns'].to_i + 1
    @conversation.update!(additional_attributes: attrs)
  rescue StandardError => e
    Rails.logger.error "[Ai::Gateway#bump_step_turns_unless_advanced] ticket_id=#{@conversation&.id} #{e.class}: #{e.message}"
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
      conversation: @conversation, account: @account, agent: @agent, mode: @mode, acts_live: @acts_live,
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
  # A etapa :department (classificação de departamento) foi eliminada por completo (19/08, fusão
  # Departamento -> Agente — o agente já vem resolvido antes do Gateway rodar, não há mais nada pra
  # classificar). 'classification_failed' fica sem produtor a partir daqui; mantido em
  # Ai::Run::ERROR_TYPES só pelo histórico de runs antigos.
  def classify_error(exception)
    timed_out = timeout_error?(exception)
    case @stage
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

  # Cluster de handoff/atribuição extraído do Gateway (Passo 1 da quebra do God object): route IA->IA,
  # resolução do time de destino e entrega a um humano. Memoizado — criado 1x por run, sob demanda.
  def handoff_coordinator
    @handoff_coordinator ||= Ai::HandoffCoordinator.new(
      conversation: @conversation, account: @account, agent: @agent, message: @message
    )
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
    Rails.logger.error "[Ai::Gateway#maybe_notify_low_balance] ticket_id=#{@conversation&.id} #{e.class}: #{e.message}"
  end

  def current_plan_credits_cap
    @account.subscriptions.current.first&.plan&.ai_credits_included.to_i
  end

  # Handoff forçado quando o saldo de créditos de IA esgota: nota interna + entrega ao humano no time
  # PADRÃO do agente (transfer + assign). NÃO envia texto ao cliente (a IA simplesmente não responde;
  # um humano assume).
  def force_credit_handoff(run_record)
    action_dispatcher.internal_note('⚠️ Crédito de IA esgotado — atendimento transferido para um humano.')
    team_id = handoff_coordinator.human_team_id({})
    input = { 'unassign' => true }
    input['team_id'] = team_id if team_id
    action_dispatcher.execute_action('conversation.transfer', input, run_record, 'handoff', extra: { reason: 'credit_exhausted' })
    handoff_coordinator.assign_human(team_id, reason: 'credit_exhausted')
    emit(run_record, 'handoff.credit_exhausted', { team_id: team_id })
  rescue StandardError => e
    Rails.logger.error "[Ai::Gateway#force_credit_handoff] ticket_id=#{@conversation&.id} #{e.class}: #{e.message}"
  end

  # Handoff forçado quando o PERFIL estoura o orçamento mensal configurado com on_limit: 'stop'.
  # Espelha force_credit_handoff (mesmo padrão: nota interna + transfer + assign, sem texto ao
  # cliente) — a diferença é o motivo (orçamento do perfil, não saldo da conta) e que aqui sempre
  # avisa o admin por e-mail (não é opcional feito o :notify de force_provider_handoff), porque um
  # "stop" silencioso deixaria o dono sem saber por que a IA parou.
  def force_budget_handoff(run_record)
    profile = @agent.operation_profile
    action_dispatcher.internal_note("⚠️ Orçamento do perfil \"#{profile.name}\" esgotado — atendimento transferido para um humano.")
    team_id = handoff_coordinator.human_team_id({})
    input = { 'unassign' => true }
    input['team_id'] = team_id if team_id
    action_dispatcher.execute_action('conversation.transfer', input, run_record, 'handoff', extra: { reason: 'budget_exceeded' })
    handoff_coordinator.assign_human(team_id, reason: 'budget_exceeded')
    emit(run_record, 'handoff.budget_exceeded', { team_id: team_id, profile_id: profile.id })
    notify_admin_budget_exceeded(stopped: true)
  rescue StandardError => e
    Rails.logger.error "[Ai::Gateway#force_budget_handoff] ticket_id=#{@conversation&.id} #{e.class}: #{e.message}"
  end

  # E-mail aos admins quando o orçamento do perfil estoura — throttled 1x/dia por perfil (BUDGET_NOTIFY_TTL).
  # Best-effort: qualquer falha aqui só loga; nunca derruba o handoff/turno que já ocorreu.
  def notify_admin_budget_exceeded(stopped:)
    profile = @agent.operation_profile
    return unless budget_notify_allows?(profile.id)

    AdministratorNotifications::AccountNotificationMailer
      .with(account: @account)
      .budget_exceeded(@account, profile.name, profile.month_to_date_cost.round(2), profile.budget_monthly_usd.round(2), stopped)
      .deliver_later
  rescue StandardError => e
    Rails.logger.error "[Ai::Gateway#notify_admin_budget_exceeded] ticket_id=#{@conversation&.id} #{e.class}: #{e.message}"
  end

  def budget_notify_allows?(profile_id)
    key = "ai:budget_notify:#{profile_id}"
    return false if Rails.cache.read(key)

    Rails.cache.write(key, true, expires_in: BUDGET_NOTIFY_TTL)
    true
  end

  # Transferência silenciosa ao atingir o teto de respostas (max_replies). Espelha force_credit_handoff:
  # nota interna ao atendente + transfer + assign_human, SEM mensagem ao cliente. Não usa reply() para
  # o aviso porque o próprio gate de max_replies bloquearia a mensagem — o humano recebe e responde ele mesmo.
  def force_max_replies_handoff(run_record)
    max = @agent.behavior.to_h['max_replies'].to_i
    action_dispatcher.internal_note("⚠️ Limite de #{max} respostas da IA atingido — atendimento transferido para um humano.")
    team_id = handoff_coordinator.human_team_id({})
    input = { 'unassign' => true }
    input['team_id'] = team_id if team_id
    action_dispatcher.execute_action('conversation.transfer', input, run_record, 'handoff', extra: { reason: 'max_replies_reached' })
    handoff_coordinator.assign_human(team_id, reason: 'max_replies_reached')
    emit(run_record, 'handoff.max_replies_reached', { max: max, team_id: team_id })
  rescue StandardError => e
    Rails.logger.error "[Ai::Gateway#force_max_replies_handoff] ticket_id=#{@conversation&.id} #{e.class}: #{e.message}"
  end

  def max_replies_reached?
    max = @agent.behavior.to_h['max_replies'].to_i
    max.positive? && Ai::Event.where(conversation_id: @conversation.id, event_type: 'reply.sent').count >= max
  end

  # Teto configurável por tipo de anexo (áudio em segundos, documento em caracteres). 0/ausente = sem
  # limite pro tipo. Sem entrada pra imagem de propósito — ver o comentário de
  # Ai::Workers::MediaProcessor#oversized_attachment_type.
  def attachment_limits
    behavior = @agent.behavior.to_h
    {
      audio_max_seconds: behavior['max_audio_seconds'].to_i,
      document_max_chars: behavior['max_document_chars'].to_i
    }
  end

  # Mensagem ao cliente quando um anexo estoura o teto do seu tipo — editável por tipo no agente
  # (max_audio_message/max_document_message), com um default em português por tipo.
  def oversized_attachment_message(kind)
    behavior = @agent.behavior.to_h
    if kind == 'audio'
      behavior['max_audio_message'].presence ||
        'O áudio que você enviou é grande demais. Pode mandar um áudio mais curto ou escrever, por favor? 🙂'
    else
      behavior['max_document_message'].presence ||
        'O arquivo que você enviou é grande demais. Pode mandar uma versão menor, por favor? 🙂'
    end
  end

  # true quando o auto-relato de confiança do modelo (result[:confidence], já vindo do Python) está
  # abaixo do teto configurado (agent.transfer_rules['min_confidence'], tela "Transferir se a IA
  # estiver insegura"). 0/ausente = desligado (Ai::HandoffEvaluator::DEFAULT_MIN_CONFIDENCE). Reusa o
  # MESMO evaluator do motor legado — só o decision hash muda de forma (aqui é sempre 'reply', já que
  # 'handoff' já teria sido tratado via result[:transferred] antes de chegar aqui).
  def low_confidence?(confidence)
    Ai::HandoffEvaluator.evaluate(decision: { 'decision' => 'reply', 'confidence' => confidence }, agent: @agent)[:handoff]
  end

  # Transferência silenciosa quando a IA reporta baixa confiança na resposta deste turno. Espelha
  # force_max_replies_handoff/force_stuck_step_handoff: nota interna + transfer + assign_human, SEM
  # mandar a resposta incerta ao cliente.
  def force_low_confidence_handoff(run_record, confidence)
    action_dispatcher.internal_note("⚠️ A IA reportou baixa confiança (#{confidence.inspect}) na resposta deste " \
                                    'turno — atendimento transferido para um humano.')
    team_id = handoff_coordinator.human_team_id({})
    input = { 'unassign' => true }
    input['team_id'] = team_id if team_id
    action_dispatcher.execute_action('conversation.transfer', input, run_record, 'handoff', extra: { reason: 'low_confidence' })
    handoff_coordinator.assign_human(team_id, reason: 'low_confidence')
    emit(run_record, 'handoff.low_confidence', { confidence: confidence, team_id: team_id })
  rescue StandardError => e
    Rails.logger.error "[Ai::Gateway#force_low_confidence_handoff] ticket_id=#{@conversation&.id} #{e.class}: #{e.message}"
  end

  # Transferência forçada ao atingir stuck_handoff_turns (achado ao vivo 13/08, ver comentário no
  # #run). Espelha force_max_replies_handoff/force_credit_handoff: nota interna + transfer +
  # assign_human, SEM mensagem ao cliente (o gate acima já impede o modelo de responder este turno).
  def force_stuck_step_handoff(run_record)
    action_dispatcher.internal_note('⚠️ A IA ficou travada na mesma etapa sem avançar — atendimento transferido para um humano.')
    team_id = handoff_coordinator.human_team_id({})
    input = { 'unassign' => true }
    input['team_id'] = team_id if team_id
    action_dispatcher.execute_action('conversation.transfer', input, run_record, 'handoff', extra: { reason: 'stuck_handoff_turns' })
    handoff_coordinator.assign_human(team_id, reason: 'stuck_handoff_turns')
    emit(run_record, 'handoff.stuck_step', { team_id: team_id })
  rescue StandardError => e
    Rails.logger.error "[Ai::Gateway#force_stuck_step_handoff] ticket_id=#{@conversation&.id} #{e.class}: #{e.message}"
  end

  # Provider de IA indisponível (rate-limit/cota/billing, ou auth não recuperado pelo BYOK): a IA não
  # conseguiu decidir. Espelha o force_credit_handoff: NOTA PRIVADA ao atendente com o motivo técnico (que o
  # cliente nunca vê) + transferência + assign_human. reason 'provider_unavailable' -> resumo + card.
  # DECISÃO DE PRODUTO: NÃO manda mensagem automática ao cliente — a conversa cai no time humano e o
  # atendente responde ele mesmo (uma frase "já vou te atender" seria mais uma promessa que o sistema não
  # cumpre, o padrão que estamos eliminando). Só ao vivo (o call-site já gateia @acts_live).
  # notify: (Fase 3) — o e-mail da Fase 2 sai só na ABERTURA do breaker (a chamada que REALMENTE falhou),
  # NÃO a cada transferência com o breaker JÁ aberto. O caminho normal (Fase 1/2) chama sem argumento =>
  # notify:true, comportamento IDÊNTICO ao de antes. Só o skip do breaker aberto passa notify:false (ali não
  # houve chamada nem provider_error novo — e run_record.provider nem está setado).
  # Provider resolvido do perfil (fallback 'openai' — hoje o único que o orchestrator.py suporta, ver
  # Ai::PythonMigrationAuditor). Serve ao breaker tanto no gate pré-chamada quanto no record pós-chamada.
  def supervisor_provider
    @agent.operation_profile&.supervisor_provider.presence || 'openai'
  end

  # Fallback pro cálculo de custo quando o Python não devolveu o model usado (turno que falhou antes
  # de qualquer chamada real chegar ao fim — ver Ai::PythonOrchestratorClient). Não muda o que É
  # cobrado, só evita Ai::ModelRouter.price_for(nil) caindo cego no preço-padrão de segurança.
  def supervisor_model
    @agent.operation_profile&.supervisor_model
  end

  # Breaker por (conta, provider) memoizado no run — o mesmo objeto para o gate pré-chamada e o record
  # pós-chamada (estado real vive no cache, não no objeto).
  def provider_breaker
    @provider_breaker ||= Ai::ProviderBreaker.new(account: @account, provider: supervisor_provider)
  end

  def force_provider_handoff(run_record, notify: true)
    action_dispatcher.internal_note('⚠️ Transferido automaticamente: a IA não conseguiu responder por ' \
                                    'indisponibilidade do provedor de IA (verifique cota/billing).')
    team_id = handoff_coordinator.human_team_id({})
    input = { 'unassign' => true }
    input['team_id'] = team_id if team_id
    action_dispatcher.execute_action('conversation.transfer', input, run_record, 'handoff', extra: { reason: 'provider_unavailable' })
    handoff_coordinator.assign_human(team_id, reason: 'provider_unavailable')
    emit(run_record, 'handoff.provider_unavailable', { team_id: team_id })
    # Fase 2: avisa os ADMINS da conta (cota/billing é de quem paga, não do atendente). DEPOIS do handoff
    # e best-effort — nunca derruba a transferência (ver #notify_admin_provider_error). Fase 3: com o breaker
    # ABERTO o Gateway pula a chamada e transfere sem provider_error novo — passa notify:false para NÃO
    # reenviar; o aviso já saiu na abertura (a 3ª falha, throttle de 1h). Ver #run e Ai::ProviderBreaker.
    notify_admin_provider_error(run_record.provider) if notify
  rescue StandardError => e
    Rails.logger.error "[Ai::Gateway#force_provider_handoff] ticket_id=#{@conversation&.id} #{e.class}: #{e.message}"
  end

  # E-mail aos admins da conta quando um provider_error resulta em handoff. Reusa o padrão do
  # notify_admin_no_agent (AccountNotificationMailer.with(account:) + throttle por cache). Throttle de
  # 1 HORA por (conta, provedor): cota estourada é condição SUSTENTADA — o admin quer UM aviso, não
  # dezenas (por isso a janela é maior que os 15 min do notify_admin_no_agent). Best-effort: qualquer
  # falha aqui (mailer, cache) só loga; o handoff já ocorreu e não pode ser afetado.
  def notify_admin_provider_error(provider)
    return unless provider_error_notify_allows?(provider)

    AdministratorNotifications::AccountNotificationMailer
      .with(account: @account)
      .provider_error_handoff(@account, provider.to_s)
      .deliver_later
  rescue StandardError => e
    Rails.logger.error "[Ai::Gateway#notify_admin_provider_error] ticket_id=#{@conversation&.id} #{e.class}: #{e.message}"
  end

  # Persiste o conversation_id da Responses API em additional_attributes da conversa.
  # NÃO usa @conversation.lock! — lock! lança RuntimeError quando o objeto tem mudanças em memória
  # não persistidas (dirty object, frequente no fim do run quando StateManager/ActionDispatcher
  # setam estado sem salvar). Solução: instância NOVA via SELECT FOR UPDATE (nunca dirty) +
  # update_columns (sem callbacks/validações, equivalente ao update_column do lock! original).
  def persist_openai_conversation_id(conv_id)
    return if conv_id.blank?

    ::Conversation.transaction do
      fresh = ::Conversation.lock.find_by(id: @conversation.id)
      next unless fresh

      attrs = (fresh.additional_attributes || {}).dup
      next if attrs['openai_conversation_id'] == conv_id

      fresh.update_columns(additional_attributes: attrs.merge('openai_conversation_id' => conv_id))
    end
  rescue StandardError => e
    Rails.logger.warn "[Ai::Gateway#persist_openai_conversation_id] ticket_id=#{@conversation&.id} #{e.class}: #{e.message}"
  end

  # notify_throttle_allows? do HandoffCoordinator (perder o estado = no máximo 1 e-mail extra), mas
  # chave e janela PRÓPRIAS — não altera o comportamento daquele. Escreve a marca ao permitir.
  def provider_error_notify_allows?(provider)
    key = "ai:provider_error_notify:#{@account.id}:#{provider}"
    return false if Rails.cache.read(key)

    Rails.cache.write(key, true, expires_in: PROVIDER_ERROR_NOTIFY_TTL)
    true
  end

  # BYOK (billing Fase 3): cobra 1 crédito SCNET da chamada que teve que cair pra chave global porque
  # a chave própria da conta falhou por auth (Python já fez o retry — ver orchestrator.py). Achado no
  # merge com a eliminação do motor legado (13/08): o #maybe_byok_fallback antigo (retry client-side,
  # só do caminho legado) foi removido de propósito, mas esta cobrança e a tag de visibilidade abaixo
  # são chamadas pelo NOVO bloco BYOK em #run — precisam sobreviver à eliminação, não são código morto.
  def consume_byok_fallback_credit
    balance = AiCreditBalance.find_or_create_by(account_id: @account.id)
    balance.consume!(1)
  rescue AiCreditBalance::InsufficientCredits => e
    Rails.logger.info "[Ai::Gateway] ticket_id=#{@conversation&.id} fallback BYOK sem saldo SCNET: #{e.message}"
  rescue StandardError => e
    Rails.logger.error "[Ai::Gateway#consume_byok_fallback_credit] ticket_id=#{@conversation&.id} #{e.class}: #{e.message}"
  end

  # Tag de visibilidade best-effort.
  def apply_label(label)
    Ai::CapabilityRegistry.execute('conversation.add_label', conversation: @conversation, input: { 'label' => label })
  rescue StandardError => e
    Rails.logger.error "[Ai::Gateway#apply_label] ticket_id=#{@conversation&.id} #{e.class}: #{e.message}"
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
