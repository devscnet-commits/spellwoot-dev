# Periodic SLA sweep: closes/reclassifies AI-managed conversations whose response window
# elapsed without customer activity. Shadow-aware: only records intention for shadow bindings;
# executes for live ones. Schedule via sidekiq-cron (e.g. every 15 min); can also run manually.
#
# Department SLA shape (jsonb): { "response_timeout_minutes": 120, "on_timeout": "resolve" }
class Ai::SlaSweepJob < ApplicationJob
  queue_as :low

  def perform
    Ai::AgentInbox.where(active: true).includes(:agent).find_each do |binding|
      department = binding.agent.departments.active.first
      next if department.nil?

      timeout = department.sla['response_timeout_minutes'].to_i
      next unless timeout.positive?

      sweep(binding, department, timeout.minutes.ago)
    end
  end

  private

  def sweep(binding, department, cutoff)
    account_id = binding.agent.account_id
    # The per-department auto_attendance toggle is a kill switch for every autonomous action.
    acts_live = binding.mode == 'live' && department.behavior.to_h['auto_attendance'] != false
    Conversation.where(inbox_id: binding.inbox_id, status: :open)
                .where('last_activity_at < ?', cutoff)
                .find_each do |conversation|
      if acts_live && department.sla['on_timeout'].to_s == 'resolve'
        Ai::CapabilityRegistry.execute('conversation.resolve', conversation: conversation, input: {})
        emit(account_id, conversation.id, 'sla.closed', { executed: true })
      else
        emit(account_id, conversation.id, 'sla.intended', { executed: false, reason: sla_skip_reason(binding, acts_live) })
      end
    rescue StandardError => e
      Rails.logger.error "[Ai::SlaSweepJob] conv=#{conversation.id} #{e.class}: #{e.message}"
    end
  end

  def sla_skip_reason(binding, acts_live)
    return binding.mode unless binding.mode == 'live'

    acts_live ? 'on_timeout_none' : 'auto_attendance_off'
  end

  def emit(account_id, conversation_id, type, payload)
    Ai::Event.create!(account_id: account_id, conversation_id: conversation_id, event_type: type, payload: payload)
  end
end
