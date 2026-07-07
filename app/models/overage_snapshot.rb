# Snapshot diário do excedente de um limite em paid_overage. 1 linha por (conta, chave, dia) —
# ver índice único. Base para a média do ciclo (OverageCharge). Ver Billing::OverageSnapshotJob.
class OverageSnapshot < ApplicationRecord
  belongs_to :account

  validates :plan_limit_key, presence: true,
                             uniqueness: { scope: %i[account_id snapshot_date] }
  validates :snapshot_date, presence: true
  validates :excess_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
end
