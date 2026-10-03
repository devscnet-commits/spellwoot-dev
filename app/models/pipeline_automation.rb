# An automation attached to a pipeline stage. trigger_type decides when it runs:
#   stage_entered  right after a card enters the stage
#   time_in_stage  delay_minutes after the card entered the stage
#   inactivity     delay_minutes without new messages; inactivity_sender narrows it to who sent the
#                  last message (contact = the company did not answer, agent = the customer went quiet)
# conditions: [{ attribute:, operator:, value:, attribute_key: }] combined by match_type (all = E,
# any = OU); actions: [{ action_name:, action_params: {} }].
# == Schema Information
#
# Table name: pipeline_automations
#
#  id                  :bigint           not null, primary key
#  actions             :jsonb            not null
#  activated_at        :datetime
#  active              :boolean          default(TRUE), not null
#  conditions          :jsonb            not null
#  delay_minutes       :integer          default(0), not null
#  inactivity_sender   :string           default("any"), not null
#  match_type          :string           default("all"), not null
#  name                :string           not null
#  sort_order          :integer          default(0), not null
#  trigger_type        :string           default("stage_entered"), not null
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  account_id          :bigint           not null
#  operational_flow_id :bigint           not null
#  resolution_state_id :bigint           not null
#
# Indexes
#
#  index_pipeline_automations_on_account_id               (account_id)
#  index_pipeline_automations_on_active_and_trigger_type  (active,trigger_type)
#  index_pipeline_automations_on_operational_flow_id      (operational_flow_id)
#  index_pipeline_automations_on_resolution_state_id      (resolution_state_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id) ON DELETE => cascade
#  fk_rails_...  (operational_flow_id => operational_flows.id) ON DELETE => cascade
#  fk_rails_...  (resolution_state_id => resolution_states.id) ON DELETE => cascade
#
class PipelineAutomation < ApplicationRecord
  TRIGGER_TYPES = %w[stage_entered time_in_stage inactivity].freeze
  INACTIVITY_SENDERS = %w[contact agent any].freeze
  MATCH_TYPES = %w[all any].freeze
  CONDITION_ATTRIBUTES = %w[label priority team_id assignee_id custom_attribute sla temperature status].freeze
  OPERATORS = %w[equal_to not_equal_to is_present is_not_present greater_than less_than].freeze
  ACTIONS = %w[send_message add_private_note send_template send_webhook create_conversation move_stage assign_team
               assign_agent change_priority add_label remove_label add_sla remove_sla change_status change_temperature].freeze

  belongs_to :account
  belongs_to :operational_flow
  belongs_to :resolution_state
  has_many :runs, class_name: 'PipelineAutomationRun', dependent: :delete_all

  validates :name, presence: true
  validates :trigger_type, inclusion: { in: TRIGGER_TYPES }
  validates :match_type, inclusion: { in: MATCH_TYPES }
  validates :inactivity_sender, inclusion: { in: INACTIVITY_SENDERS }
  validates :delay_minutes, numericality: { greater_than_or_equal_to: 0 }
  validate :stage_belongs_to_flow
  validate :known_actions

  before_validation :inherit_flow_from_stage
  before_save :stamp_activation

  TRIGGER_ATTRIBUTES = %w[trigger_type inactivity_sender resolution_state_id].freeze

  scope :active, -> { where(active: true) }

  private

  def inherit_flow_from_stage
    self.operational_flow_id ||= resolution_state&.operational_flow_id
    self.account_id ||= operational_flow&.account_id
  end

  # Turning a rule on (or creating it on) marks the moment: only what happens after it counts.
  # Changing what it reacts to (trigger, who was silent, stage) is a new rule for the same reason,
  # so the backlog that already matches it is not hit in one burst.
  def stamp_activation
    return unless active
    return unless activated_at.nil? || active_changed? || changed.intersect?(TRIGGER_ATTRIBUTES)

    self.activated_at = Time.current
  end

  def stage_belongs_to_flow
    return if resolution_state.nil? || resolution_state.operational_flow_id == operational_flow_id

    errors.add(:resolution_state, 'must belong to the pipeline')
  end

  def known_actions
    names = Array(actions).map { |action| action.to_h['action_name'].to_s }
    errors.add(:actions, 'cannot be empty') if names.empty?
    errors.add(:actions, 'contain an unknown action') if (names - ACTIONS).any?
  end
end
