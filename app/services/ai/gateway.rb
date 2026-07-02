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
    emit(run_record, 'message.received', { content: @message.content.to_s.first(500) })

    # Invisible worker: turn media (audio/image) into text the supervisor can use.
    media_text = Ai::Workers::MediaProcessor.process(@message)
    emit(run_record, 'media.preprocessed', { text: media_text }) if media_text.present?
    base_content = @content_override.presence || @message.content
    effective_content = [base_content, media_text].compact.join("\n").strip

    @stage = :department
    department, resolution = Ai::DepartmentResolver.resolve(
      agent: @agent, inbox_id: @message.inbox_id, message_content: effective_content
    )
    emit(run_record, 'department.resolved', { department_id: department&.id, name: department&.name, method: resolution })
    return finalize(run_record, 'no_department') unless department

    run_record.update!(ai_department_id: department.id)

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
    knowledge = Ai::KnowledgeRetriever.retrieve(query: effective_content, account_id: @account.id)
    emit(run_record, 'knowledge.retrieved', { count: knowledge.size, preview: knowledge.first(2) })
    run_record.update!(knowledge_count: knowledge.size)

    memory = Ai::AgentMemory.find_by(conversation_id: @conversation.id, ai_agent_id: @agent.id)
    tools  = department.tools.active.to_a
    @stage = :context
    system_prompt = Ai::PromptCompiler.compile(
      agent: @agent, department: department, knowledge: knowledge, memory: memory, tools: tools,
      collected: (@conversation.contact&.custom_attributes || {})
        .merge(@conversation.custom_attributes || {}),
      fillable_attributes: context_builder.fillable_attributes(department)
    )
    emit(run_record, 'context.assembled', { prompt_chars: system_prompt.length, tools: tools.map(&:name) })

    @stage = :decision
    result = Ai::ModelRouter.decide(
      profile: @agent.operation_profile, system_prompt: system_prompt,
      user_message: context_builder.user_message(effective_content), account_id: @account.id
    )
    run_record.update!(
      provider: result[:provider], model: result[:model],
      tokens_in: result[:tokens_in], tokens_out: result[:tokens_out],
      cost: result[:cost], latency_ms: result[:latency_ms],
      decision: result[:decision] || {}, status: result[:status],
      error_type: (result[:status] == 'error' ? 'provider_error' : nil)
    )
    emit(run_record, 'decision.made',
         { decision: result[:decision], cost: result[:cost], latency_ms: result[:latency_ms] },
         run_id: run_record.id)

    # Track which step the conversation is on so message grouping can use that step's delay.
    track_step(department, result[:decision] || {}) if @acts_live
    # Grava os dados coletados (cidade, plano, etc.) nos atributos da conversa, conforme o modelo
    # devolveu em `attributes`. Assim os campos vão sendo alimentados e reaproveitados (não repergunta).
    persist_attributes(run_record, (result[:decision] || {})['attributes']) if @acts_live

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
    # Intelligent handoff / close. Shadow records intention; live executes the native action.
    handoff = Ai::HandoffEvaluator.evaluate(
      decision: result[:decision] || {}, department: department, message_content: effective_content
    )
    decision_kind = (result[:decision] || {})['decision']
    if handoff[:handoff]
      # Try AI->AI routing first (to an allowed agent); otherwise hand to a human.
      routed = @acts_live && handoff_coordinator.route_to_ai(result[:decision] || {})
      unless routed
        # Tell the customer we're handing off (the model's "transferindo você..." text), THEN
        # transfer (reopen + unassign for a human). Without the reply the customer saw silence.
        action_dispatcher.reply(department, (result[:decision] || {})['reply_text'])
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
      action_dispatcher.reply(department, (result[:decision] || {})['reply_text'])
    elsif intended_tool.present? && @acts_live
      # Safety net: a tool ran but the follow-up decision still isn't a plain reply/close/handoff —
      # send whatever text we have so the customer is never left waiting after a tool call.
      action_dispatcher.reply(department, (result[:decision] || {})['reply_text'])
    end

    update_memory(run_record)
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

  # Persiste nos atributos da conversa os dados que o modelo coletou (campo `attributes` da decisão).
  # Merge, ignora vazios e no-ops. Na próxima volta o PromptCompiler injeta como "Dados já coletados".
  def persist_attributes(run_record, attrs)
    return unless attrs.is_a?(Hash)

    cleaned = attrs.reject { |_k, v| v.to_s.strip.empty? }
    return if cleaned.empty?

    merged = (@conversation.custom_attributes || {}).merge(cleaned)
    return if merged == @conversation.custom_attributes

    @conversation.update!(custom_attributes: merged)
    emit(run_record, 'attributes.updated', { keys: cleaned.keys })
  rescue StandardError => e
    Rails.logger.error "[Ai::Gateway#persist_attributes] #{e.class}: #{e.message}"
  end

  # Execução de ações do pipeline (reply + capabilities nativas), extraído do Gateway (Passo 3).
  # Memoizado — depende de @acts_live, então SÓ é acessado depois da resolução do gate (linha ~52).
  def action_dispatcher
    @action_dispatcher ||= Ai::ActionDispatcher.new(
      conversation: @conversation, account: @account, mode: @mode, acts_live: @acts_live
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
  def classify_error(exception)
    timed_out = timeout_error?(exception)
    case @stage
    when :knowledge  then 'knowledge_timeout'                    # busca RAG/pgvector
    when :tool       then 'tool_failed'                          # executor de ferramenta estourou
    when :department then 'classification_failed'                # roteamento/classificação
    when :decision   then timed_out ? 'provider_timeout' : 'provider_error'
    else                  timed_out ? 'provider_timeout' : 'unknown'
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
      user_message: followup_message, account_id: @account.id
    )
    emit(run_record, 'tool.followup',
         { decision: result[:decision], cost: result[:cost], latency_ms: result[:latency_ms] })
    result
  rescue StandardError => e
    Rails.logger.error "[Ai::Gateway#tool_followup] #{e.class}: #{e.message}"
    { decision: {} }
  end

  # Stores the conversation's current step + its grouping delay (from the playbook) so the next
  # message-grouping debounce can use the step-specific delay. Falls back to the general delay
  # when the step has no delay configured (handled in Ai::MessageGrouping).
  def track_step(department, decision)
    name = decision['current_step'].to_s.strip
    return if name.blank?

    steps = Array(department.playbook&.steps)
    step = steps.find { |s| s.is_a?(Hash) && (s['name'] || s[:name]).to_s.strip.casecmp?(name) }
    delay = (step && (step['group_delay_seconds'] || step[:group_delay_seconds])).to_i

    attrs = @conversation.additional_attributes || {}
    attrs['ai_step'] = { 'name' => name, 'grouping_delay_seconds' => (delay.positive? ? delay : nil) }
    @conversation.update!(additional_attributes: attrs)
  rescue StandardError => e
    Rails.logger.error "[Ai::Gateway#track_step] #{e.class}: #{e.message}"
  end

  # Cluster de handoff/atribuição extraído do Gateway (Passo 1 da quebra do God object): route IA->IA,
  # resolução do time de destino e entrega a um humano. Memoizado — criado 1x por run, sob demanda.
  def handoff_coordinator
    @handoff_coordinator ||= Ai::HandoffCoordinator.new(
      conversation: @conversation, account: @account, agent: @agent, message: @message
    )
  end

  # Invisible worker: persist a rolling conversation summary into agent memory.
  def update_memory(run_record)
    summary = Ai::Workers::Summary.generate(conversation: @conversation, agent: @agent)
    return if summary.blank?

    Ai::AgentMemory.find_or_initialize_by(conversation_id: @conversation.id, ai_agent_id: @agent.id)
                   .update!(summary: summary)
    emit(run_record, 'memory.updated', { chars: summary.length })
  rescue StandardError => e
    Rails.logger.error "[Ai::Gateway#memory] #{e.class}: #{e.message}"
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
