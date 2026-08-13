# Machine-to-machine endpoint called by the Python AI orchestrator, either mid function-calling loop
# (OpenAI invoking a Rails-side admin-configured tool) or — since the Structured Outputs refactor,
# orchestrator.py — for the five control actions Python itself dispatches from the model's parsed JSON
# reply (dados_coletados/avancar_etapa/transferir_humano/encerrar_atendimento): "registrar_*"/
# "salvar_memoria_ia" (Ai::StepCaptureTool / free-form save — a playbook step's collect slot, or
# anything else), "avancar_etapa" (agentic step advance — the model decides, not a server-side index
# gate), "conversation.resolve"/"conversation.transfer" (close/handoff), and "continuar_conversa"
# (legacy no-op, no longer called — kept recognized here for backward compatibility, harmless). None
# of these five are a configured Ai::Tool row — they're recognized by name, same as the legacy path's
# non-tool decision fields (handoff/close). Real (admin-configured) tools still delegate to the
# existing Ai::ToolExecutor/Ai::CapabilityRegistry framework — same audited path
# (Ai::CapabilityExecution) used by Ai::Gateway's own tool handling.
#
# Name translation: Ai::PythonOrchestratorClient SANITIZES every tool name before it reaches OpenAI
# (Ai::ToolNameSanitizer — OpenAI 400s on anything outside [a-zA-Z0-9_-], and Ai::CapabilityRegistry's
# whole convention is dotted keys). Python calls back with that SAME sanitized name, so every lookup
# here resolves it against the real candidate set (CONTROL_CAPABILITIES / the department's own tool
# names) instead of guessing what character a "_" used to be.
class Api::Internal::AiExecuteToolController < ActionController::API
  before_action :authenticate_internal_request!

  CONTROL_CAPABILITIES = [Ai::PythonOrchestratorClient::RESOLVE_TOOL, Ai::PythonOrchestratorClient::TRANSFER_TOOL].freeze

  def create
    conversation = ::Conversation.find(params[:ticket_id])
    department = Ai::Department.find(params[:ai_department_id])
    # Multi-tenant guard: the department must belong to the SAME account as the conversation. Without
    # this, a malformed/forged payload could execute one account's tool against another account's
    # conversation. This endpoint already sits behind the internal Bearer token (authenticate_internal_request!),
    # so 403 here doesn't expose anything to an unauthenticated caller — only to whoever already holds that token.
    unless department.account_id == conversation.account_id
      return render json: { error: 'forbidden' }, status: :forbidden
    end

    return render json: continue_conversation if params[:tool_name] == Ai::PythonOrchestratorClient::CONTINUE_TOOL

    return render json: advance_step(conversation, department) if params[:tool_name] == Ai::PythonOrchestratorClient::ADVANCE_STEP_TOOL

    control_key = resolve_control_capability(params[:tool_name])
    return render json: run_capability(conversation, control_key) if control_key

    attribute = Ai::StepCaptureTool.attribute_for(params[:tool_name])
    return render json: capture_attribute(conversation, department, attribute) if attribute

    return render json: save_memory(conversation, department) if params[:tool_name] == Ai::PythonOrchestratorClient::MEMORY_TOOL

    return render json: search_knowledge(department) if params[:tool_name] == Ai::PythonOrchestratorClient::KNOWLEDGE_TOOL

    tool = find_real_tool!(department, params[:tool_name])

    execution = Ai::ToolExecutor.new(
      tool: tool,
      input: arguments,
      conversation: conversation,
      mode: mode
    ).perform

    render json: { result: execution.output, status: execution.status, error: execution.error }
  rescue ActiveRecord::RecordNotFound => e
    render json: { error: e.message }, status: :not_found
  end

  private

  # nil when tool_name doesn't sanitize-match either control capability (not a control tool call).
  def resolve_control_capability(sanitized_name)
    CONTROL_CAPABILITIES.find { |key| Ai::ToolNameSanitizer.sanitize(key) == sanitized_name }
  end

  # Ai::Tool#name has no format validation — an admin could type spaces/accents/dots into it, which
  # Ai::PythonOrchestratorClient would ALSO have sanitized on the way out. Resolve against the
  # department's own (real, unsanitized) tool names before hitting the DB by name.
  def find_real_tool!(department, sanitized_name)
    tools = department.tools.active.to_a
    original_name = Ai::ToolNameSanitizer.resolve(sanitized_name, tools.map(&:name))
    tools.find { |t| t.name == original_name } ||
      raise(ActiveRecord::RecordNotFound, "Couldn't find Ai::Tool with name=#{sanitized_name.inspect}")
  end

  def mode
    params[:mode].presence || 'shadow'
  end

  # Same live/shadow discipline Ai::ToolExecutor already enforces for real tools — shadow never
  # mutates, it only records that the AI WOULD have acted, so a department piloted behind canary/
  # shadow doesn't leak side effects (step advance, resolve, transfer) into real conversation state.
  def live?
    mode == 'live'
  end

  def arguments
    params[:arguments].present? ? params[:arguments].to_unsafe_h : {}
  end

  # Upsert (Ai::StateManager#persist_attributes merges by key — calling this again with a corrected
  # value UPDATES ai_collected_facts, never duplicates).
  def capture_attribute(conversation, department, attribute)
    return { result: {}, status: 'skipped', error: nil } unless live?

    persist_and_report(conversation, department, attribute, arguments[attribute])
  end

  # Híbrido, deliberado (Ai::PythonOrchestratorClient::MEMORY_TOOL comment): "registrar_*" continua
  # sendo a via pra atributo JÁ conhecido (collect/CustomAttributeDefinition) — o NOME da tool garante
  # a chave exata, sem risco de a IA inventar uma chave livre que não bate com nenhum
  # CustomAttributeDefinition (já aconteceu neste projeto — "cidade_usuario" em vez de "cidade" — e o
  # espelhamento pra custom_attributes falhou em silêncio). "salvar_memoria_ia" é só pro que SOBRA:
  # contexto sem tool dedicada. Mesmo mecanismo de persistência (persist_attributes, source: :trusted,
  # sem gate) — se a IA por acaso usar uma chave que JÁ é um CustomAttributeDefinition real, espelha
  # igual a qualquer outro dado :trusted; não há proteção especial contra isso aqui, é o mesmo
  # comportamento de qualquer escrita confiável.
  def save_memory(conversation, department)
    return { result: {}, status: 'skipped', error: nil } unless live?

    chave = arguments['chave'].to_s.strip
    return { result: {}, status: 'skipped', error: 'chave vazia — nada foi registrado' } if chave.blank?

    persist_and_report(conversation, department, chave, arguments['valor'])
  end

  def persist_and_report(conversation, department, key, value)
    gated = Ai::StateManager.new(conversation: conversation, agent: department.agent)
                            .persist_attributes({ key => value }, department, source: :trusted)
    persisted = gated.key?(key)
    { result: { key => value }, status: persisted ? 'executed' : 'skipped',
      error: persisted ? nil : 'valor vazio — nada foi registrado' }
  end

  # RAG agentic (Ai::PythonOrchestratorClient::KNOWLEDGE_TOOL): a IA chamou "consultar_conhecimento" NO
  # MEIO do turno (function-calling de verdade, não um control tool disparado depois do JSON parseado —
  # ver comentário de #knowledge_tool). Roda em QUALQUER modo, live OU shadow: é leitura pura, sem
  # efeito colateral nenhum pra proteger — diferente de capture_attribute/save_memory/advance_step, que
  # gateiam por live? porque ESCREVEM estado da conversa. Isto fecha o gap de "RAG vazio silencioso": o
  # resultado da busca é sempre um function_call_output que a IA precisa processar, mesmo quando é
  # "nada encontrado" — nunca mais um bloco de prompt que simplesmente não aparece sem avisar ninguém.
  def search_knowledge(department)
    query = arguments['pergunta'].to_s.strip
    return { result: {}, status: 'skipped', error: 'pergunta vazia — nada foi buscado' } if query.blank?

    chunks = Ai::KnowledgeRetriever.retrieve(query: query, account_id: department.account_id, department_id: department.id)
    conteudo = chunks.present? ? chunks.join("\n---\n") : 'Nada encontrado na base de conhecimento para essa pergunta.'
    { result: { 'encontrado' => chunks.present?, 'conteudo' => conteudo }, status: 'executed', error: nil }
  rescue StandardError => e
    category = knowledge_error_category(e)
    Rails.logger.error "[Api::Internal::AiExecuteToolController#search_knowledge] #{category} #{e.class}: #{e.message}"
    # Categorizado (equivalente ao knowledge_timeout do motor legado — Ai::Run::ERROR_TYPES ainda lista
    # a categoria, só não tinha mais nenhum emissor vivo): sem isso, um timeout/erro na busca virava 500
    # cru pro Python, sem sinal nenhum de PORQUE a ferramenta falhou. Devolve como qualquer outra tool
    # (result/status/error) para a IA poder seguir a conversa em vez de travar o turno inteiro.
    { result: {}, status: 'failed', error: category }
  end

  # Nomes de classe (comparados por NOME, não pela constante — Faraday/PG podem não estar carregados
  # neste processo) que denotam timeout/queda de conexão. Mesmo critério de Ai::Gateway#timeout_error?,
  # duplicado aqui de propósito: este controller não referencia estado/instância do Gateway (mesmo
  # padrão de #execute_step_conclusion, que espelha Ai::Gateway#force_conclusion em vez de reusar).
  KNOWLEDGE_TIMEOUT_ERROR_NAMES = %w[
    Timeout::Error Net::OpenTimeout Net::ReadTimeout Errno::ETIMEDOUT
    Faraday::TimeoutError PG::QueryCanceled ActiveRecord::StatementTimeout ActiveRecord::QueryCanceled
  ].freeze

  def knowledge_error_category(exception)
    ancestors = exception.class.ancestors.filter_map(&:name)
    timed_out = (ancestors & KNOWLEDGE_TIMEOUT_ERROR_NAMES).any? || exception.message.to_s.downcase.include?('timeout')
    timed_out ? 'knowledge_timeout' : 'knowledge_search_failed'
  end

  # "continuar_conversa" (Ai::PythonOrchestratorClient::CONTINUE_TOOL): pure no-op, NEVER touches the
  # database — it exists only so tool_choice="required" (orchestrator.py) always has a safe option
  # when the model just wants to talk (greet, ask, answer) without registering data or advancing the
  # step. No live/shadow gate either: there's no side effect to distinguish.
  def continue_conversation
    { result: 'ok', status: 'executed', error: nil }
  end

  # Agentic step advance: the AI decides a step is done (or the customer declined an optional field)
  # and calls this — Rails only clamps at the last step and resets ai_step_turns (Ai::Gateway's
  # stuck-turn ceiling counts turns SINCE the last genuine advance, mirroring the legacy path's
  # Gap 4 semantics without reusing its decision-shaped Ai::StepResolver machinery).
  #
  # on_complete (desfecho declarado NA ETAPA que está sendo concluída — "Encerrar o atendimento" no
  # AiStepForm.vue): GAP real achado em auditoria (13/08) — nunca foi lido no caminho Python; a etapa
  # só avançava o índice, o desfecho configurado nunca disparava. Mesmo padrão de leitura de campo da
  # etapa que já existe pra transferir_humano/encerrar_atendimento (o Python NÃO injeta texto extra de
  # despedida aqui — a "mensagem_para_cliente" do próprio turno do modelo já é o texto ao cliente,
  # igual os outros dois campos; force_conclusion do motor legado injetava close_farewell porque ali o
  # texto do modelo era outra coisa — aqui NÃO é). Espelha Ai::Gateway#force_conclusion (motor legado)
  # nas 3 ações, sem reusar Ai::ActionDispatcher (não existe fora do Gateway) — usa Ai::CapabilityRegistry
  # direto, igual #run_capability já faz pras outras 2 control tools.
  def advance_step(conversation, department)
    return { result: {}, status: 'skipped', error: nil } unless live?

    steps = Array(department.playbook&.steps)
    return { result: {}, status: 'skipped', error: 'sem etapas configuradas' } if steps.empty?

    attrs = conversation.additional_attributes || {}
    current_index = attrs['ai_step_index'].to_i.clamp(0, steps.size - 1)
    current_step = steps[current_index]
    on_complete = current_step.is_a?(Hash) ? (current_step['on_complete'] || current_step[:on_complete]) : nil
    return execute_step_conclusion(conversation, department, on_complete) if on_complete.is_a?(Hash)

    new_index = [current_index + 1, steps.size - 1].min
    attrs['ai_step_index'] = new_index
    attrs['ai_step_turns'] = 0
    conversation.update!(additional_attributes: attrs)
    { result: { 'ai_step_index' => new_index }, status: 'executed', error: nil }
  end

  # As 3 ações do desfecho declarado — espelha Ai::Gateway#force_conclusion (motor legado) exatamente,
  # trocando action_dispatcher/handoff_coordinator memoizados do Gateway por instâncias locais (este
  # controller não tem run_record nem @acts_live — roda direto, o gate live? já filtrou acima).
  def execute_step_conclusion(conversation, department, info)
    case info['action'].to_s
    when 'close'
      result = Ai::CapabilityRegistry.execute(Ai::PythonOrchestratorClient::RESOLVE_TOOL,
                                              conversation: conversation, input: {})
      { result: { 'conclusion' => 'close' }.merge(result[:output].is_a?(Hash) ? result[:output] : {}),
        status: 'executed', error: nil }
    when 'handoff_ai'
      routed = step_handoff_coordinator(conversation, department).route_to_ai({ 'handoff_target' => info['target'].to_s })
      { result: { 'conclusion' => 'handoff_ai', 'target' => info['target'], 'routed' => routed ? true : false },
        status: 'executed', error: nil }
    else # handoff_human (default) — mesma leitura de team que Ai::Gateway#force_conclusion
      coordinator = step_handoff_coordinator(conversation, department)
      team_id = coordinator.conclusion_team_id(info)
      reason = info['reason'].presence || 'conclusao'
      transfer_input = { 'unassign' => true }
      transfer_input['team_id'] = team_id if team_id
      Ai::CapabilityRegistry.execute(Ai::PythonOrchestratorClient::TRANSFER_TOOL,
                                     conversation: conversation, input: transfer_input)
      coordinator.assign_human(team_id, reason: reason)
      { result: { 'conclusion' => 'handoff_human', 'team_id' => team_id }, status: 'executed', error: nil }
    end
  rescue StandardError => e
    Rails.logger.error "[Api::Internal::AiExecuteToolController#execute_step_conclusion] #{e.class}: #{e.message}"
    { result: {}, status: 'failed', error: e.message }
  end

  # Ai::HandoffCoordinator exige um `message` (route_to_ai usa .inbox_id/.id pra reenfileirar o
  # GatewayRunJob) — este controller não recebe o message_id que disparou o turno (o payload Rails->
  # Python nunca mandou), então usa a ÚLTIMA mensagem incoming da conversa como substituta razoável
  # (mesma inbox, é o que dispararia o próximo turno de qualquer forma).
  def step_handoff_coordinator(conversation, department)
    Ai::HandoffCoordinator.new(conversation: conversation, account: department.account, agent: department.agent,
                               message: conversation.messages.incoming.order(:id).last)
  end

  # conversation.resolve / conversation.transfer: direct Ai::CapabilityRegistry calls (same registry
  # Ai::ToolExecutor dispatches to for configured tools) — not routed through Ai::ToolExecutor because
  # these aren't admin-configured Ai::Tool rows, they're always-available control tools. No
  # Ai::CapabilityExecution audit row for the same reason "avancar_etapa"/"registrar_*" don't have one.
  def run_capability(conversation, key)
    return { result: {}, status: 'skipped', error: nil } unless live?

    save_handoff_summary(conversation) if key == Ai::PythonOrchestratorClient::TRANSFER_TOOL
    result = Ai::CapabilityRegistry.execute(key, conversation: conversation, input: arguments)
    { result: result[:output], status: 'executed', error: nil }
  rescue StandardError => e
    Rails.logger.error "[Api::Internal::AiExecuteToolController#run_capability] #{key}: #{e.class}: #{e.message}"
    { result: {}, status: 'failed', error: e.message }
  end

  # A IA é instruída (Ai::PythonOrchestratorClient#tool_usage_instruction) a SEMPRE preencher
  # handoff_summary ao chamar conversation.transfer — resumo do que já foi conseguido + o motivo,
  # pro humano que assumir não começar do zero. Salvo ANTES de executar a capability (que reabre/
  # desatribui a conversa) para não depender de ordem de commit entre as duas escritas.
  def save_handoff_summary(conversation)
    summary = arguments['handoff_summary'].to_s.strip
    return if summary.blank?

    attrs = conversation.additional_attributes || {}
    attrs['handoff_summary'] = summary
    conversation.update!(additional_attributes: attrs)
  end

  def authenticate_internal_request!
    expected = ENV.fetch('INTERNAL_AI_TOKEN', nil)
    token = request.headers['Authorization'].to_s.sub(/\ABearer\s+/i, '')
    return render json: { error: 'unauthorized' }, status: :unauthorized if expected.blank? || token.blank?
    return if ActiveSupport::SecurityUtils.secure_compare(token, expected)

    render json: { error: 'unauthorized' }, status: :unauthorized
  end
end
