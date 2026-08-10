# Machine-to-machine endpoint called by the Python AI orchestrator mid function-calling loop, when
# OpenAI decides to invoke a Rails-side (non-native) tool OR one of the synthetic "registrar_*"
# capture tools (Ai::StepCaptureTool — a playbook step's collect slot, exposed as a function so the
# model reports data via a structured call instead of free text). Real tools delegate to the
# existing Ai::ToolExecutor/Ai::CapabilityRegistry framework — same audited path (Ai::CapabilityExecution)
# used by Ai::Gateway's own tool handling. Capture tools are NOT a configured tool (no admin-facing
# Ai::Tool row, no CapabilityExecution audit row) — they're a direct write into ai_collected_facts via
# the same Ai::StateManager#persist_attributes every other capture path (SlotCollector, tool
# auto-fill) already uses.
class Api::Internal::AiExecuteToolController < ActionController::API
  before_action :authenticate_internal_request!

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

    attribute = Ai::StepCaptureTool.attribute_for(params[:tool_name])
    return render json: capture_attribute(conversation, department, attribute) if attribute

    tool = department.tools.active.find_by!(name: params[:tool_name])

    execution = Ai::ToolExecutor.new(
      tool: tool,
      input: arguments,
      conversation: conversation,
      mode: params[:mode].presence || 'shadow'
    ).perform

    render json: { result: execution.output, status: execution.status, error: execution.error }
  rescue ActiveRecord::RecordNotFound => e
    render json: { error: e.message }, status: :not_found
  end

  private

  def arguments
    params[:arguments].present? ? params[:arguments].to_unsafe_h : {}
  end

  def capture_attribute(conversation, department, attribute)
    value = arguments[attribute]
    gated = Ai::StateManager.new(conversation: conversation, agent: department.agent)
                            .persist_attributes({ attribute => value }, department, source: :trusted)
    persisted = gated.key?(attribute)
    { result: { attribute => value }, status: persisted ? 'executed' : 'skipped',
      error: persisted ? nil : 'valor vazio — nada foi registrado' }
  end

  def authenticate_internal_request!
    expected = ENV.fetch('INTERNAL_AI_TOKEN', nil)
    token = request.headers['Authorization'].to_s.sub(/\ABearer\s+/i, '')
    return render json: { error: 'unauthorized' }, status: :unauthorized if expected.blank? || token.blank?
    return if ActiveSupport::SecurityUtils.secure_compare(token, expected)

    render json: { error: 'unauthorized' }, status: :unauthorized
  end
end
