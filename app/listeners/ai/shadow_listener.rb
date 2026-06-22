# Observes inbound messages and, only for inboxes that have a SHADOW AI binding, enqueues the
# shadow run. Does nothing for inboxes without a shadow agent — zero impact otherwise.
class Ai::ShadowListener < BaseListener
  def message_created(event)
    message = event.data[:message]
    return if message.blank?
    return unless message.incoming?
    return if message.private?
    return unless message.account&.feature_enabled?('ai_core')
    return unless Ai::AgentInbox.shadow.exists?(inbox_id: message.inbox_id)

    Ai::ShadowRunJob.perform_later(message.id)
  end
end
