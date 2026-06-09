# A ClosingRequirement makes a custom attribute mandatory before a conversation can be resolved
# under a given OperationalFlow. The condition decides when it applies, keyed on the chosen
# resolution state's canonical_key/polarity rather than on any display label.
class ClosingRequirement < ApplicationRecord
  belongs_to :operational_flow

  validates :attribute_key, presence: true, uniqueness: { scope: :operational_flow_id }

  # Whether this requirement applies given the resolution state the agent is closing with.
  def applies_to?(state)
    return true if condition['always']

    when_clause = condition['when']
    return true if when_clause.blank?
    return state&.canonical_key.to_s == when_clause['canonical_key'].to_s if when_clause.key?('canonical_key')
    return state&.polarity.to_s == when_clause['polarity'].to_s if when_clause.key?('polarity')

    true
  end
end
