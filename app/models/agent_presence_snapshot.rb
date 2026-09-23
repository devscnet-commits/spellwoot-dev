# Per-minute snapshot of an agent's OnlineStatusTracker status, written by AgentPresenceSnapshotJob.
# == Schema Information
#
# Table name: agent_presence_snapshots
#
#  id          :bigint           not null, primary key
#  recorded_at :datetime         not null
#  status      :string           not null
#  account_id  :bigint           not null
#  user_id     :bigint           not null
#
# Indexes
#
#  index_agent_presence_snapshots_on_account_user_time  (account_id,user_id,recorded_at)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (user_id => users.id)
#
class AgentPresenceSnapshot < ApplicationRecord
  belongs_to :account
  belongs_to :user
end
