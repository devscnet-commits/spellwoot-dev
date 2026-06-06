# An OperationalFlow is the configuration owned by a Caixa (Inbox). A conversation inherits its
# flow from its inbox. Each flow defines the result reasons (motivos) available when resolving a
# conversation as won/lost, and whether a reason is mandatory.
class OperationalFlow < ApplicationRecord
  belongs_to :account
  has_many :reasons, class_name: 'OperationalFlowReason', dependent: :destroy, inverse_of: :operational_flow
  has_many :inboxes, dependent: :nullify

  accepts_nested_attributes_for :reasons, allow_destroy: true

  validates :name, presence: true, uniqueness: { scope: :account_id }

  def reasons_for(result)
    reasons.where(active: true, result: result).order(:position)
  end
end
