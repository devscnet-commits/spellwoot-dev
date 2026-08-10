# Machine-to-machine endpoint called by the Python AI orchestrator mid function-calling loop, when
# OpenAI decides to invoke a Rails-side (non-native) tool. Delegates execution to the existing
# Ai::ToolExecutor/Ai::CapabilityRegistry framework — same audited path (Ai::CapabilityExecution)
# used by Ai::Gateway's own tool handling, so tool calls made via Python are audited identically.
class Api::Internal::AiExecuteToolController < ActionController::API
  before_action :authenticate_internal_request!

  def create
    conversation = ::Conversation.find(params[:ticket_id])
    department = Ai::Department.find(params[:ai_department_id])
    tool = department.tools.active.find_by!(name: params[:tool_name])

    execution = Ai::ToolExecutor.new(
      tool: tool,
      input: params[:arguments].present? ? params[:arguments].to_unsafe_h : {},
      conversation: conversation,
      mode: params[:mode].presence || 'shadow'
    ).perform

    render json: { result: execution.output, status: execution.status, error: execution.error }
  rescue ActiveRecord::RecordNotFound => e
    render json: { error: e.message }, status: :not_found
  end

  private

  def authenticate_internal_request!
    expected = ENV.fetch('INTERNAL_AI_TOKEN', nil)
    token = request.headers['Authorization'].to_s.sub(/\ABearer\s+/i, '')
    return render json: { error: 'unauthorized' }, status: :unauthorized if expected.blank? || token.blank?
    return if ActiveSupport::SecurityUtils.secure_compare(token, expected)

    render json: { error: 'unauthorized' }, status: :unauthorized
  end
end
