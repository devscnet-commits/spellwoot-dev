# Snapshot diário do excedente de um limite em paid_overage. 1 linha por (conta, chave, dia) —
# ver índice único. Base para a média do ciclo (OverageCharge). Ver Billing::OverageSnapshotJob.
# == Schema Information
#
# Table name: overage_snapshots
#
#  id             :bigint           not null, primary key
#  excess_count   :integer          default(0), not null
#  plan_limit_key :string           not null
#  snapshot_date  :date             not null
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#  account_id     :bigint           not null
#
# Indexes
#
#  index_overage_snapshots_on_account_id  (account_id)
#  index_overage_snapshots_unique_daily   (account_id,plan_limit_key,snapshot_date) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#
class OverageSnapshot < ApplicationRecord
  belongs_to :account

  validates :plan_limit_key, presence: true,
                             uniqueness: { scope: %i[account_id snapshot_date] }
  validates :snapshot_date, presence: true
  validates :excess_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
end
