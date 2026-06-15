# A ClosingRequirement makes a custom attribute mandatory before a conversation can be resolved
# under a given OperationalFlow. The condition decides when it applies: always, keyed on the chosen
# resolution state (canonical_key/polarity), or keyed on another attribute's value ("required IF
# attribute = one of these answers").
class ClosingRequirement < ApplicationRecord
  belongs_to :operational_flow

  validates :attribute_key, presence: true, uniqueness: { scope: :operational_flow_id }

  # Whether this requirement applies given the resolution state the agent is closing with and the
  # conversation's custom attributes (used by "if attribute = value" conditions).
  def applies_to?(state, custom_attributes = {})
    return attribute_value_match?(custom_attributes) if condition['if'].present?
    return true if condition['always']

    when_clause = condition['when']
    return true if when_clause.blank?
    return state&.canonical_key.to_s == when_clause['canonical_key'].to_s if when_clause.key?('canonical_key')
    return state&.polarity.to_s == when_clause['polarity'].to_s if when_clause.key?('polarity')

    true
  end

  private

  def attribute_value_match?(custom_attributes)
    clause = condition['if']
    values = Array(clause['values']).map(&:to_s)
    # A half-configured condition (no trigger attribute or no values) never requires the field.
    return false if clause['attribute_key'].blank? || values.empty?

    actual = custom_attributes.with_indifferent_access[clause['attribute_key']]
    values.include?(actual.to_s)
  end
end
