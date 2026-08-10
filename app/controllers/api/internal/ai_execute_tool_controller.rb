# Machine-to-machine endpoint called by the Python AI orchestrator mid function-calling loop, when
# OpenAI decides to invoke a Rails-side (non-native) tool OR one of the synthetic control tools
# Ai::PythonOrchestratorClient always offers on this path: "registrar_*" (Ai::StepCaptureTool — a
# playbook step's collect slot), "avancar_etapa" (agentic step advance — the model decides, not a
# server-side index gate), and "conversation.resolve"/"conversation.transfer" (close/handoff). None
# of these four are a configured Ai::Tool row — they're recognized by name, same as the legacy
# path's non-tool decision fields (handoff/close), just reached via function-calling here instead of
# a JSON decision contract. Real (admin-configured) tools still delegate to the existing
# Ai::ToolExecutor/Ai::CapabilityRegistry framework — same audited path (Ai::CapabilityExecution)
# used by Ai::Gateway's own tool handling.
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

    return render json: advance_step(conversation, department) if params[:tool_name] == Ai::PythonOrchestratorClient::ADVANCE_STEP_TOOL
    return render json: run_capability(conversation, params[:tool_name]) if CONTROL_CAPABILITIES.include?(params[:tool_name])

    attribute = Ai::StepCaptureTool.attribute_for(params[:tool_name])
    return render json: capture_attribute(conversation, department, attribute) if attribute

    tool = department.tools.active.find_by!(name: params[:tool_name])

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

    value = arguments[attribute]
    gated = Ai::StateManager.new(conversation: conversation, agent: department.agent)
                            .persist_attributes({ attribute => value }, department, source: :trusted)
    persisted = gated.key?(attribute)
    { result: { attribute => value }, status: persisted ? 'executed' : 'skipped',
      error: persisted ? nil : 'valor vazio — nada foi registrado' }
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

    result = Ai::CapabilityRegistry.execute(key, conversation: conversation, input: arguments)
    { result: result[:output], status: 'executed', error: nil }
  rescue StandardError => e
    Rails.logger.error "[Api::Internal::AiExecuteToolController#run_capability] #{key}: #{e.class}: #{e.message}"
    { result: {}, status: 'failed', error: e.message }
  end

  def authenticate_internal_request!
    expected = ENV.fetch('INTERNAL_AI_TOKEN', nil)
    token = request.headers['Authorization'].to_s.sub(/\ABearer\s+/i, '')
    return render json: { error: 'unauthorized' }, status: :unauthorized if expected.blank? || token.blank?
    return if ActiveSupport::SecurityUtils.secure_compare(token, expected)

    render json: { error: 'unauthorized' }, status: :unauthorized
  end
end
