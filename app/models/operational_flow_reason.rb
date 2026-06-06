class OperationalFlowReason < ApplicationRecord
  belongs_to :operational_flow

  enum result: { won: 1, lost: 2 }, _prefix: :result

  validates :label, presence: true
  validates :result, presence: true
end
