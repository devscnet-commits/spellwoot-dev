# Observes inbound messages and enqueues the Gateway run for inboxes that have an active AI
# binding (shadow OR live). Shadow only records; live may reply, still gated by the department
# reply_scope (canary by default). Does nothing for inboxes without an active binding.
class Ai::ShadowListener < BaseListener
  def message_created(event)
    message = event.data[:message]
    return if message.blank?
    return unless message.incoming?
    return if message.private?
    return unless message.account&.feature_enabled?('ai_core')
    return unless Ai::AgentInbox.where(inbox_id: message.inbox_id, active: true).exists?

    Ai::ShadowRunJob.perform_later(message.id)
  end
end
