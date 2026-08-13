# Gateway entry point: observes inbound messages and enqueues the Gateway run for inboxes with an
# active AI binding (shadow OR live). This is mandatory plumbing for the AI runtime — not the
# optional "shadow" validation feature. The binding mode drives behaviour: shadow only records;
# live may reply, still gated by the department reply_scope (canary by default). No active binding
# => no-op.
class Ai::GatewayListener < BaseListener
  def message_created(event)
    message = event.data[:message]
    return if message.blank?
    return unless message.incoming?
    return if message.private?
    return unless message.account&.feature_enabled?('ai_core')
    return unless Ai::AgentInbox.where(inbox_id: message.inbox_id, active: true).exists?

    # Message grouping: when a department sets a delay, defer the run so a burst of messages is
    # answered once (the deferred job processes only the last message and groups the burst).
    delay = Ai::MessageGrouping.delay_seconds(message.inbox_id, conversation: message.conversation)
    if delay.positive?
      Ai::GatewayRunJob.set(wait: delay.seconds).perform_later(message.id, grouped: true)
    else
      Ai::GatewayRunJob.perform_later(message.id)
    end
  end
end
