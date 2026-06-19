# Periodic follow-up sweep: nudges customers who received an AI/agent reply and went quiet.
# Only live bindings act, and every send goes through Ai::ReplyPolicy (canary / business hours /
# kill switch). One follow-up per silence: it won't fire again until the customer writes back.
#
# Department follow_up shape (jsonb): { "enabled": true, "delay_minutes": 60, "message": "..." }
class Ai::FollowupSweepJob < ApplicationJob
  queue_as :low

  def perform
    Ai::AgentInbox.live.includes(:agent).find_each do |binding|
      department = binding.agent.departments.active.first
      next if department.nil?

      follow_up = department.follow_up.to_h
      next unless follow_up['enabled'] && follow_up['message'].present?

      delay = follow_up['delay_minutes'].to_i
      next unless delay.positive?

      sweep(binding, department, follow_up, delay.minutes.ago)
    end
  end

  private

  def sweep(binding, department, follow_up, cutoff)
    account_id = binding.agent.account_id
    Conversation.where(inbox_id: binding.inbox_id, status: :open)
                .where('last_activity_at < ?', cutoff)
                .find_each do |conversation|
      next unless awaiting_customer?(conversation) && !already_followed_up?(conversation)

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

  # We only nudge when the last real message was ours (the customer is the one who went quiet).
  def awaiting_customer?(conversation)
    last = conversation.messages.where(message_type: %i[incoming outgoing]).order(:created_at).last
    last&.outgoing?
  end

  # Already nudged this silence? Skip until the customer writes again (a newer incoming message).
  def already_followed_up?(conversation)
    last_incoming_at = conversation.messages.incoming.maximum(:created_at)
    scope = Ai::Event.where(conversation_id: conversation.id, event_type: 'followup.sent')
    scope = scope.where('created_at > ?', last_incoming_at) if last_incoming_at
    scope.exists?
  end

  def emit(account_id, conversation_id, type, payload)
    Ai::Event.create!(account_id: account_id, conversation_id: conversation_id, event_type: type, payload: payload)
  end
end
