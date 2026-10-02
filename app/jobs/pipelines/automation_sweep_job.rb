# Every minute: finds the cards for which a time-based stage automation (time in stage, inactivity,
# AI follow-up cadence) became due and enqueues one run per card. Idempotent — the run ledger and the
# re-check in Pipelines::AutomationRunner keep a card from getting the same automation twice.
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
end
