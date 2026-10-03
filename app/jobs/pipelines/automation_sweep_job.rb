# Every minute: finds the cards for which a time-based stage automation (time in stage, inactivity)
# became due and enqueues one run per card; also enqueues the AI follow-up cadence of each stage for
# its open cards (Pipelines::AiFollowupRunner decides whether something is due). Idempotent — the run
# ledger / the ai_events and the re-checks keep a card from getting the same thing twice.
class Pipelines::AutomationSweepJob < ApplicationJob
  queue_as :scheduled_jobs

  LOCK_KEY = 'pipelines:automation_sweep'.freeze
  LOCK_TTL = 2.minutes

  def perform
    lock = Redis::LockManager.new
    return unless lock.lock(LOCK_KEY, LOCK_TTL)

    begin
      sweep
    ensure
      lock.unlock(LOCK_KEY)
    end
  end

  private

  def sweep
    enabled = Hash.new { |cache, account| cache[account] = account.feature_enabled?('crm_automations') }
    sweep_automations(enabled)
    sweep_ai_followups(enabled)
  end

  def sweep_automations(enabled)
    PipelineAutomation.active.where(trigger_type: %w[time_in_stage inactivity])
                      .includes(:account, :operational_flow).find_each do |automation|
      next unless automation.operational_flow.active && enabled[automation.account]

      Pipelines::AutomationSchedule.new(automation).due_runs.each do |conversation_id, anchor|
        Pipelines::AutomationRunJob.perform_later(automation.id, conversation_id, anchor.iso8601(6))
      end
    rescue StandardError => e
      ChatwootExceptionTracker.new(e, account: automation.account).capture_exception
    end
  end

  def sweep_ai_followups(enabled)
    PipelineAiFollowup.active.includes(:account, :operational_flow).find_each do |cadence|
      next unless cadence.operational_flow.active && enabled[cadence.account] && cadence.account.feature_enabled?('ai_core')

      Conversation.where(pipeline_stage_id: cadence.resolution_state_id, status: %i[open pending], group_chat: false)
                  .where('conversations.last_activity_at < ?', cadence.min_quiet_minutes.minutes.ago)
                  .pluck(:id).each { |conversation_id| Pipelines::AiFollowupRunJob.perform_later(cadence.id, conversation_id) }
    rescue StandardError => e
      ChatwootExceptionTracker.new(e, account: cadence.account).capture_exception
    end
  end
end
