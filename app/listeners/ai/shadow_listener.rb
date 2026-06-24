# Triggers Shadow quality evaluation when a conversation is resolved on an observed inbox.
class Ai::ShadowListener < BaseListener
  def conversation_resolved(event)
    conversation = extract_conversation_and_account(event)[0]
    return if conversation.blank?
    return unless conversation.account&.feature_enabled?('ai_core')
    return unless Ai::ShadowInbox.where(inbox_id: conversation.inbox_id).exists?

    Ai::ShadowEvalJob.perform_later(conversation.id)
  end
end
