# Periodic follow-up sweep: nudges customers who received an AI/agent reply and went quiet.
# Only live bindings act, and every send goes through Ai::ReplyPolicy (canary / business hours /
# kill switch).
#
# Department follow_up shape (jsonb):
#   { "enabled": true, "message": "...", "delay_minutes": 60 (interval between nudges),
#     "max_followups": 3 (after this many with no reply, hand to a human; 0 = unlimited),
#     "when_agents_online": false (skip if a human is already handling, unless true),
#     "window_start": "08:00", "window_end": "18:00" (only send within this window; blank = always) }
class Ai::FollowupSweepJob < ApplicationJob
  queue_as :low

  def perform
    Ai::AgentInbox.live.includes(agent: :account).find_each do |binding|
      next unless binding.agent.account&.feature_enabled?('ai_core')

      department = binding.agent.departments.active.first
      next if department.nil?

      follow_up = department.follow_up.to_h
      next unless follow_up['enabled'] && follow_up['message'].present?

      interval = follow_up['delay_minutes'].to_i
      next unless interval.positive?
      next unless within_window?(follow_up)

      sweep(binding, department, follow_up, interval)
    end
  end

  private

  def sweep(binding, department, follow_up, interval)
    account_id = binding.agent.account_id
    Conversation.where(inbox_id: binding.inbox_id, status: :open)
                .where('last_activity_at < ?', interval.minutes.ago)
                .find_each do |conversation|
      next unless awaiting_customer?(conversation)
      next if conversation.assignee_id.present? && !follow_up['when_agents_online']

      sent = followups_since_incoming(conversation)
      max = follow_up['max_followups'].to_i
      if max.positive? && sent.count >= max
        hand_off(conversation, account_id)
        next
      end

      # Space successive nudges by the interval (measured from the last nudge, or last activity).
      last_at = sent.maximum(:created_at) || conversation.last_activity_at
      next if last_at && last_at > interval.minutes.ago

      send_follow_up(binding, department, follow_up, conversation, account_id)
    rescue StandardError => e
      Rails.logger.error "[Ai::FollowupSweepJob] conv=#{conversation.id} #{e.class}: #{e.message}"
    end
  end

  def send_follow_up(binding, department, follow_up, conversation, account_id)
    if Ai::ReplyPolicy.allowed?(mode: binding.mode, department: department, conversation: conversation)
      Messages::MessageBuilder.new(nil, conversation, { content: follow_up['message'], private: false }).perform
      emit(account_id, conversation.id, 'followup.sent', { chars: follow_up['message'].to_s.length })
    else
      reason = Ai::ReplyPolicy.skip_reason(mode: binding.mode, department: department, conversation: conversation)
      emit(account_id, conversation.id, 'followup.intended', { executed: false, reason: reason })
    end
  end

  # After the configured number of unanswered follow-ups, stop nudging and flag the conversation
  # for a human (unassign so it returns to the queue). Recorded so the team can act / report.
  def hand_off(conversation, account_id)
    incoming_at = last_incoming_at(conversation) || conversation.created_at
    already = Ai::Event.where(conversation_id: conversation.id, event_type: 'followup.handoff')
                       .where('created_at > ?', incoming_at).exists?
    return if already

    conversation.update!(assignee_id: nil) if conversation.assignee_id.present?
    emit(account_id, conversation.id, 'followup.handoff', { reason: 'max_followups_reached' })
  end

  # We only nudge when the last real message was ours (the customer is the one who went quiet).
  def awaiting_customer?(conversation)
    last = conversation.messages.where(message_type: %i[incoming outgoing]).order(:created_at).last
    last&.outgoing?
  end

  def last_incoming_at(conversation)
    conversation.messages.incoming.maximum(:created_at)
  end

  # Follow-ups already sent in this silence (since the customer's last incoming message).
  def followups_since_incoming(conversation)
    scope = Ai::Event.where(conversation_id: conversation.id, event_type: 'followup.sent')
    incoming_at = last_incoming_at(conversation)
    incoming_at ? scope.where('created_at > ?', incoming_at) : scope
  end

  # Restrict sends to the configured time window (server time). Supports overnight ranges.
  def within_window?(follow_up)
    start_at = follow_up['window_start'].to_s
    end_at = follow_up['window_end'].to_s
    return true if start_at.blank? || end_at.blank?

    now = Time.current.strftime('%H:%M')
    start_at <= end_at ? now.between?(start_at, end_at) : (now >= start_at || now <= end_at)
  end

  def emit(account_id, conversation_id, type, payload)
    Ai::Event.create!(account_id: account_id, conversation_id: conversation_id, event_type: type, payload: payload)
  end
end
