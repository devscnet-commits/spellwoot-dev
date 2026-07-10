# Account-scoped, dev-time prompt/step-instructions assistant. Suggestion-only; nothing is sent to
# any customer. Uses ::Ai::PromptAssistant (top-level) to avoid namespace collision.
class Api::V1::Accounts::AiPromptAssistantController < Api::V1::Accounts::BaseController
  def create
    render json: ::Ai::PromptAssistant.new(
      account: Current.account, kind: params[:kind], brief: params[:brief], requested_by: Current.user&.id
    ).suggest
  end
end
