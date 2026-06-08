# An OperationalFlow is assigned to Caixas (Inboxes) and/or Teams. A conversation inherits its
# flow from its inbox first, falling back to its team. Each flow defines the result reasons
# (motivos) available when resolving a conversation as won/lost, and whether a reason is mandatory.
# An inactive flow is ignored (not applied to its inboxes/teams).
class OperationalFlow < ApplicationRecord
  belongs_to :account
  has_many :reasons, class_name: 'OperationalFlowReason', dependent: :destroy, inverse_of: :operational_flow
  has_many :inboxes, dependent: :nullify
  has_many :teams, dependent: :nullify

  accepts_nested_attributes_for :reasons, allow_destroy: true

  validates :name, presence: true, uniqueness: { scope: :account_id }

  def reasons_for(result)
    reasons.where(active: true, result: result).order(:position)
  end
end
