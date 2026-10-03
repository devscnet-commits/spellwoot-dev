# The "Follow-up IA" cadence of a pipeline stage. Same model as the AI agent's own follow-up
# (Ai::Agent#follow_up), applied to the cards of the stage whoever owns them, and replacing the
# agent's follow-up while a card is in the stage:
#   behaviors: [{ context: 'inbox_hours' | 'outside_hours' | 'custom', windows: [{ start:, end: }],
#                 attempts: [{ name:, active:, delay_minutes:, inactivity_sender: 'contact' | 'agent' | 'any',
#                              ai_agent_id:, prompt: }],
#                 no_response_action: 'assign' | 'finalize' | 'discard' | 'wait' | 'wait_business_hours' | 'move_stage',
#                 no_response_stage_id: }]
# Each attempt is a message the chosen AI agent writes from its prompt once the conversation has
# been silent for delay_minutes (counted from the previous attempt); inactivity_sender narrows it
# to who sent the last message. After the last attempt and inactivity_minutes more of silence, the
# no-response action runs. The customer's next message restarts the cadence.
# == Schema Information
#
# Table name: pipeline_ai_followups
#
#  id                  :bigint           not null, primary key
#  activated_at        :datetime
#  active              :boolean          default(TRUE), not null
#  behaviors           :jsonb            not null
#  close_message       :string
#  inactivity_minutes  :integer          default(30), not null
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  account_id          :bigint           not null
#  operational_flow_id :bigint           not null
#  resolution_state_id :bigint           not null
#
# Indexes
#
#  index_pipeline_ai_followups_on_account_id           (account_id)
#  index_pipeline_ai_followups_on_operational_flow_id  (operational_flow_id)
#  index_pipeline_ai_followups_on_resolution_state_id  (resolution_state_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id) ON DELETE => cascade
#  fk_rails_...  (operational_flow_id => operational_flows.id) ON DELETE => cascade
#  fk_rails_...  (resolution_state_id => resolution_states.id) ON DELETE => cascade
#
class PipelineAiFollowup < ApplicationRecord
  CONTEXTS = %w[inbox_hours outside_hours custom].freeze
  NO_RESPONSE_ACTIONS = %w[assign finalize discard wait wait_business_hours move_stage].freeze
  INACTIVITY_SENDERS = %w[contact agent any].freeze

  belongs_to :account
  belongs_to :operational_flow
  belongs_to :resolution_state

  validates :resolution_state_id, uniqueness: true
  validates :inactivity_minutes, numericality: { greater_than_or_equal_to: 0 }
  validate :stage_belongs_to_flow
  validate :behaviors_shape

  before_validation :inherit_flow_from_stage
  before_save :stamp_activation

  scope :active, -> { where(active: true) }

  def normalized_behaviors
    Array(behaviors).map { |behavior| behavior.to_h.with_indifferent_access }
  end

  # Shortest silence (minutes) after which something of this cadence can be due — the sweep only
  # looks at cards quiet for at least that long.
  def min_quiet_minutes
    delays = normalized_behaviors.flat_map do |behavior|
      first = Array(behavior[:attempts]).map { |attempt| attempt.to_h.with_indifferent_access }.find { |attempt| attempt[:active] != false }
      first ? first[:delay_minutes].to_i : inactivity_minutes.to_i
    end
    [delays.min || inactivity_minutes.to_i, 1].max
  end

  # The first attempt of the cadence: what the card's manual "Follow-up IA" button and the inactivity
  # alert use.
  def first_attempt
    normalized_behaviors.flat_map { |behavior| Array(behavior[:attempts]) }
                        .map { |attempt| attempt.to_h.with_indifferent_access }
                        .find { |attempt| attempt[:active] != false }
  end

  private

  def inherit_flow_from_stage
    self.operational_flow_id ||= resolution_state&.operational_flow_id
    self.account_id ||= operational_flow&.account_id
  end

  def stamp_activation
    self.activated_at = Time.current if active && (activated_at.nil? || active_changed?)
  end

  def stage_belongs_to_flow
    return if resolution_state.nil? || resolution_state.operational_flow_id == operational_flow_id

    errors.add(:resolution_state, 'must belong to the pipeline')
  end

  def behaviors_shape
    normalized_behaviors.each do |behavior|
      errors.add(:behaviors, 'have an unknown context') unless CONTEXTS.include?(behavior[:context].to_s)
      errors.add(:behaviors, 'have an unknown no-response action') unless NO_RESPONSE_ACTIONS.include?(behavior[:no_response_action].to_s)
      Array(behavior[:attempts]).each { |attempt| validate_attempt(attempt.to_h.with_indifferent_access) }
    end
  end

  def validate_attempt(attempt)
    errors.add(:behaviors, 'have an attempt without an AI agent') if attempt[:ai_agent_id].blank?
    errors.add(:behaviors, 'have an unknown attempt sender') unless INACTIVITY_SENDERS.include?(attempt[:inactivity_sender].to_s)
  end
end
