# Agent-triggered copilot suggestions for a conversation. Suggestion-only; nothing is sent to
# the customer. Uses ::Ai::Copilot (top-level) to avoid namespace collision.
class Api::V1::Accounts::AiCopilotController < Api::V1::Accounts::BaseController
  def create
    conversation = Current.account.conversations.find_by(display_id: params[:conversation_id])
    return render json: { error: 'conversa não encontrada' }, status: :not_found if conversation.nil?

    render json: ::Ai::Copilot.new(conversation: conversation, requested_by: Current.user&.id).suggest
  end
end
