class OperationalFlowReason < ApplicationRecord
  belongs_to :operational_flow
  belongs_to :resolution_state, optional: true

  enum result: { won: 1, lost: 2 }, _prefix: :result

  validates :label, presence: true
  validates :result, presence: true
end
