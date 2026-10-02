# An OperationalFlow (Closing Flow) is a reusable closing policy and, with open stages, a sales
# pipeline shown as a kanban. It bundles the resolution states (open stages + closing buttons), the
# reasons (motivos) per state, the attribute requirements per stage/closing and the automations
# that run in each stage. category is a reporting dimension (sales/support) so support closings
# never pollute the sales funnel.
# == Schema Information
#
# Table name: operational_flows
#
#  id                  :bigint           not null, primary key
#  active              :boolean          default(TRUE), not null
#  category            :string           default("sales"), not null
#  meta_enabled        :boolean          default(FALSE), not null
#  name                :string           not null
#  require_reason      :boolean          default(FALSE), not null
#  value_attribute_key :string
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  account_id          :bigint           not null
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
  has_many :pipeline_automations, dependent: :destroy
  has_many :stage_events, class_name: 'ConversationStageEvent', dependent: :delete_all
  has_many :inboxes, dependent: :nullify
  has_many :teams, dependent: :nullify

  CATEGORIES = %w[sales support].freeze
  POLARITY_ORDER = { 'neutral' => 0, 'positive' => 1, 'negative' => 2 }.freeze

  accepts_nested_attributes_for :reasons, allow_destroy: true
  accepts_nested_attributes_for :resolution_states, allow_destroy: true
  accepts_nested_attributes_for :closing_requirements, allow_destroy: true

  validates :name, presence: true, uniqueness: { scope: :account_id }
  validates :category, inclusion: { in: CATEGORIES }

  after_save :sync_reason_state_links
  after_save :normalize_default_stage
  after_commit :backfill_pipeline_cards, on: [:create, :update]

  def reasons_for(result)
    reasons.where(active: true, result: result).order(:position)
  end

  def state_for(canonical_key)
    resolution_states.find_by(canonical_key: canonical_key)
  end

  # Kanban order: open stages first (by position), then the won and the lost columns.
  def ordered_stages
    resolution_states.sort_by { |state| [POLARITY_ORDER.fetch(state.polarity, 0), state.sort_order, state.id] }
  end

  def default_stage
    resolution_states.stages.reorder(is_default: :desc, sort_order: :asc).first
  end

  def pipeline?
    resolution_states.stages.exists?
  end

  # Number typed in a custom attribute: 1234.56, "1234.56" or the Brazilian "R$ 1.234,56".
  def self.parse_amount(raw)
    return raw.to_f if raw.is_a?(Numeric)

    text = raw.to_s.gsub(/[^\d,.-]/, '')
    text = text.delete('.').tr(',', '.') if text.include?(',')
    text.to_f
  end

  # Deal value of a card, read from the configured custom attribute.
  def deal_value(conversation)
    return 0 if value_attribute_key.blank?

    self.class.parse_amount(conversation.custom_attributes.to_h[value_attribute_key])
  end

  private

  # Exactly one open stage is the entry stage: the first one when none (or several) are flagged.
  def normalize_default_stage
    stages = resolution_states.stages.order(:sort_order, :id).to_a
    return if stages.empty?

    default = stages.find(&:is_default) || stages.first
    resolution_states.where(id: stages.map(&:id)).update_all(['is_default = (id = ?)', default.id]) # rubocop:disable Rails/SkipsModelValidations
  end

  # Open conversations of the teams following this flow join the board at the entry stage.
  def backfill_pipeline_cards
    Pipelines::BackfillJob.perform_later(id) if active
  end

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
