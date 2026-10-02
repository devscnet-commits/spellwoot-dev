# A ClosingRequirement makes a custom attribute mandatory under a given OperationalFlow, both to
# resolve the conversation and to move its card along the pipeline. The condition decides when it
# applies: always, keyed on the stage being entered (canonical_key/polarity) and, optionally, on
# another attribute's value ("required IF attribute <operator> value": equal_to / not_equal_to /
# is_present / is_not_present / greater_than / less_than; equal_to accepts several answers).
# == Schema Information
#
# Table name: closing_requirements
#
#  id                  :bigint           not null, primary key
#  attribute_key       :string           not null
#  condition           :jsonb            not null
#  sort_order          :integer          default(0), not null
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  operational_flow_id :bigint           not null
#
# Indexes
#
#  idx_closing_requirements_flow_attribute            (operational_flow_id,attribute_key) UNIQUE
#  index_closing_requirements_on_operational_flow_id  (operational_flow_id)
#
# Foreign Keys
#
#  fk_rails_...  (operational_flow_id => operational_flows.id)
#
class ClosingRequirement < ApplicationRecord
  belongs_to :operational_flow

  validates :attribute_key, presence: true, uniqueness: { scope: :operational_flow_id }

  # Whether this requirement applies given the stage/resolution state being entered and the
  # conversation's custom attributes (used by "if attribute = value" conditions).
  def applies_to?(state, custom_attributes = {})
    stage_match?(state) && (condition['if'].blank? || attribute_value_match?(custom_attributes))
  end

  private

  # A closing state (won/lost) applies only to itself. An open stage means "from this stage onward":
  # the later open stages and the closing columns (won and lost).
  def stage_match?(state)
    when_clause = condition['when']
    return true if condition['always'] || when_clause.blank?
    return state&.polarity.to_s == when_clause['polarity'].to_s if when_clause.key?('polarity')
    return true unless when_clause.key?('canonical_key')

    canonical_key_match?(when_clause['canonical_key'].to_s, state)
  end

  def canonical_key_match?(key, state)
    reference = operational_flow.resolution_states.find { |candidate| candidate.canonical_key == key }
    reference&.stage? ? from_stage_onward?(reference, state) : state&.canonical_key.to_s == key
  end

  def from_stage_onward?(reference, state)
    return false if state.nil?

    !state.stage? || state.sort_order >= reference.sort_order
  end

  def attribute_value_match?(custom_attributes)
    clause = condition['if']
    # A half-configured condition (no trigger attribute) never requires the field.
    return false if clause['attribute_key'].blank?

    actual = custom_attributes.with_indifferent_access[clause['attribute_key']]
    values = Array(clause['values'] || clause['value']).map(&:to_s)
    operator_match?(clause['operator'].to_s, actual, values)
  end

  def operator_match?(operator, actual, values)
    case operator
    when 'is_present' then actual.to_s.strip.present?
    when 'is_not_present' then actual.to_s.strip.blank?
    when 'not_equal_to' then values.any? && values.exclude?(actual.to_s)
    when 'greater_than', 'less_than' then compare_numbers(operator, actual, values.first)
    else values.any? && values.include?(actual.to_s)
    end
  end

  def compare_numbers(operator, actual, expected)
    return false if actual.to_s.strip.blank? || expected.to_s.strip.blank?

    left = OperationalFlow.parse_amount(actual)
    right = OperationalFlow.parse_amount(expected)
    operator == 'greater_than' ? left > right : left < right
  end
end
