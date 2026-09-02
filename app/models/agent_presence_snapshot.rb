# Per-minute snapshot of an agent's OnlineStatusTracker status, written by AgentPresenceSnapshotJob.
class AgentPresenceSnapshot < ApplicationRecord
  belongs_to :account
  belongs_to :user
end
