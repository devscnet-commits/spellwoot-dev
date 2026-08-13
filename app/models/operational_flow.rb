# An OperationalFlow (Closing Flow) is a reusable closing policy. It bundles the resolution
# states (closing buttons) available when resolving a conversation, the reasons (motivos) per
# state, and the attribute requirements that must be satisfied before closing. category is a
# reporting dimension (sales/support) so support closings never pollute the sales funnel.
# == Schema Information
#
# Table name: operational_flows
#
#  id             :bigint           not null, primary key
#  active         :boolean          default(TRUE), not null
#  category       :string           default("sales"), not null
#  meta_enabled   :boolean          default(FALSE), not null
#  name           :string           not null
#  require_reason :boolean          default(FALSE), not null
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#  account_id     :bigint           not null
#
# Indexes
#
#  index_operational_flows_on_account_id           (account_id)
#  index_operational_flows_on_account_id_and_name  (account_id,name) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#
class OperationalFlow < ApplicationRecord
  belongs_to :account
  has_many :reasons, class_name: 'OperationalFlowReason', dependent: :destroy, inverse_of: :operational_flow
  has_many :resolution_states, -> { order(:sort_order) }, dependent: :destroy, inverse_of: :operational_flow
  has_many :closing_requirements, -> { order(:sort_order) }, dependent: :destroy, inverse_of: :operational_flow
  has_many :inboxes, dependent: :nullify

  CATEGORIES = %w[sales support].freeze

  accepts_nested_attributes_for :reasons, allow_destroy: true
  accepts_nested_attributes_for :resolution_states, allow_destroy: true
  accepts_nested_attributes_for :closing_requirements, allow_destroy: true

  validates :name, presence: true, uniqueness: { scope: :account_id }
  validates :category, inclusion: { in: CATEGORIES }

  after_save :sync_reason_state_links

  def reasons_for(result)
    reasons.where(active: true, result: result).order(:position)
  end

  def state_for(canonical_key)
    resolution_states.find_by(canonical_key: canonical_key)
  end

  private

  # Keep won/lost reasons attached to their resolution state so the close UI can list reasons
  # per state. Custom states manage their own reasons directly.
  def sync_reason_state_links
    OperationalFlowReason.results.each_key do |canonical|
      state = resolution_states.find_by(canonical_key: canonical)
      next unless state

      reasons.where(result: OperationalFlowReason.results[canonical]).update_all(resolution_state_id: state.id)
    end
  end
end
