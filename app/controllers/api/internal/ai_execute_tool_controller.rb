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
  def advance_step(conversation, department)
    return { result: {}, status: 'skipped', error: nil } unless live?

    steps = Array(department.playbook&.steps)
    return { result: {}, status: 'skipped', error: 'sem etapas configuradas' } if steps.empty?

    attrs = conversation.additional_attributes || {}
    current_index = attrs['ai_step_index'].to_i.clamp(0, steps.size - 1)
    new_index = [current_index + 1, steps.size - 1].min
    attrs['ai_step_index'] = new_index
    attrs['ai_step_turns'] = 0
    conversation.update!(additional_attributes: attrs)
    { result: { 'ai_step_index' => new_index }, status: 'executed', error: nil }
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
