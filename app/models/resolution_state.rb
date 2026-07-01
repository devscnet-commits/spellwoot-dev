# A ResolutionState is a closing button within an OperationalFlow. The canonical_key is the
# immutable machine value reports and integrations read (won/lost/...); display_label is the
# free-text shown to agents and can be renamed without affecting any data. polarity drives
# reporting aggregation independent of the label.
# == Schema Information
#
# Table name: resolution_states
#
#  id                  :bigint           not null, primary key
#  canonical_key       :string           not null
#  display_label       :string           not null
#  meta_event_type     :string
#  meta_value_attr     :string
#  polarity            :string           default("neutral"), not null
#  requires_reason     :boolean          default(FALSE), not null
#  sort_order          :integer          default(0), not null
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  operational_flow_id :bigint           not null
#
# Indexes
#
#  idx_resolution_states_flow_canonical            (operational_flow_id,canonical_key) UNIQUE
#  index_resolution_states_on_operational_flow_id  (operational_flow_id)
#
# Foreign Keys
#
#  fk_rails_...  (operational_flow_id => operational_flows.id)
#
class ResolutionState < ApplicationRecord
  belongs_to :operational_flow
  has_many :reasons, class_name: 'OperationalFlowReason', dependent: :nullify, inverse_of: :resolution_state

  POLARITIES = %w[positive negative neutral].freeze

  validates :canonical_key, presence: true, uniqueness: { scope: :operational_flow_id }
  validates :display_label, presence: true
  validates :polarity, inclusion: { in: POLARITIES }
  validate :canonical_key_unchanged, on: :update

  private

  # canonical_key is immutable once persisted to keep historical results meaningful.
  def canonical_key_unchanged
    errors.add(:canonical_key, 'cannot be changed') if canonical_key_changed?
  end
end
