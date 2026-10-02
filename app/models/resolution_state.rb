# A ResolutionState is a stage of an OperationalFlow (pipeline). Neutral states are the open
# kanban stages (one of them is the default entry stage); positive/negative states are the
# closing buttons (won/lost) and the final kanban columns. The canonical_key is the immutable
# machine value reports and integrations read; display_label is the free-text shown to agents and
# can be renamed without affecting any data. polarity drives reporting aggregation.
# == Schema Information
#
# Table name: resolution_states
#
#  id                  :bigint           not null, primary key
#  canonical_key       :string           not null
#  color               :string
#  display_label       :string           not null
#  is_default          :boolean          default(FALSE), not null
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
  has_many :pipeline_automations, dependent: :destroy
  has_many :conversations, foreign_key: :pipeline_stage_id, inverse_of: :pipeline_stage, dependent: nil

  scope :stages, -> { where(polarity: 'neutral') }

  POLARITIES = %w[positive negative neutral].freeze

  validates :canonical_key, presence: true, uniqueness: { scope: :operational_flow_id }
  validates :display_label, presence: true
  validates :polarity, inclusion: { in: POLARITIES }
  validate :canonical_key_unchanged, on: :update

  before_destroy :move_cards_to_default_stage

  def stage?
    polarity == 'neutral'
  end

  private

  # Removing a stage keeps its cards on the board: they go to the pipeline's entry stage.
  def move_cards_to_default_stage
    target = operational_flow.resolution_states.stages.where(is_default: true).where.not(id: id).first
    conversations.update_all(pipeline_stage_id: target&.id) # rubocop:disable Rails/SkipsModelValidations
  end

  # canonical_key is immutable once persisted to keep historical results meaningful.
  def canonical_key_unchanged
    errors.add(:canonical_key, 'cannot be changed') if canonical_key_changed?
  end
end
