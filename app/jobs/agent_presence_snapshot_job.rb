# Runs every minute (config/schedule.yml). Mirrors OnlineStatusTracker.get_available_users — the
# exact signal auto-assignment uses to decide who's eligible — into a durable row per account/agent,
# since the Redis-backed tracker itself only ever holds the latest heartbeat (no history).
class AgentPresenceSnapshotJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform
    recorded_at = Time.current

    Account.find_in_batches do |accounts|
      accounts.each { |account| snapshot_account(account, recorded_at) }
    end
  end

  private

  def snapshot_account(account, recorded_at)
    statuses = OnlineStatusTracker.get_available_users(account.id)
    return if statuses.blank?

    rows = statuses.map do |user_id, status|
      { account_id: account.id, user_id: user_id.to_i, status: status, recorded_at: recorded_at }
    end

    AgentPresenceSnapshot.insert_all(rows)
  end
end
