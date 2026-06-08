# An OperationalFlow (Closing Flow) is a reusable closing policy. It bundles the resolution
# states (closing buttons) available when resolving a conversation, the reasons (motivos) per
# state, and the attribute requirements that must be satisfied before closing. category is a
# reporting dimension (sales/support) so support closings never pollute the sales funnel.
class OperationalFlow < ApplicationRecord
  belongs_to :account
  has_many :reasons, class_name: 'OperationalFlowReason', dependent: :destroy, inverse_of: :operational_flow
  has_many :resolution_states, -> { order(:sort_order) }, dependent: :destroy, inverse_of: :operational_flow
  has_many :closing_requirements, -> { order(:sort_order) }, dependent: :destroy, inverse_of: :operational_flow
  has_many :assignment_rules, class_name: 'FlowAssignmentRule', dependent: :destroy
  has_many :inboxes, dependent: :nullify

  CATEGORIES = %w[sales support].freeze

  accepts_nested_attributes_for :reasons, allow_destroy: true
  accepts_nested_attributes_for :resolution_states, allow_destroy: true
  accepts_nested_attributes_for :closing_requirements, allow_destroy: true

  validates :name, presence: true, uniqueness: { scope: :account_id }
  validates :category, inclusion: { in: CATEGORIES }

  def reasons_for(result)
    reasons.where(active: true, result: result).order(:position)
  end

  def state_for(canonical_key)
    resolution_states.find_by(canonical_key: canonical_key)
  end
end
