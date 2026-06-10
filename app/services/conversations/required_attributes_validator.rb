# Validates that the custom attributes required before resolving a conversation are present.
# Two sources are combined: the per-flow closing_requirements of the conversation's Closing Flow
# (resolved from the assignment rules / Caixa) and the account-level required attributes, which
# support conditional rules ("required IF attribute = value", including the system result field).
class Conversations::RequiredAttributesValidator
  SYSTEM_OUTCOME_FIELD = '__resultado_conversa__'.freeze
  RESULT_TO_SYSTEM_VALUE = { 'won' => 'ganho', 'lost' => 'perdido' }.freeze

  def initialize(conversation:, custom_attributes: nil, result: nil)
    @conversation = conversation
    @account = conversation.account
    @custom_attributes = (custom_attributes || conversation.custom_attributes || {}).with_indifferent_access
    @result = (result || conversation.result).to_s
  end

  def valid?
    missing_keys.empty?
  end

  def missing_keys
    (flow_missing_keys + account_missing_keys).uniq
  end

  private

  def flow
    return @flow if @flow_loaded

    @flow_loaded = true
    @flow = @conversation.operational_flow
  end

  def flow_missing_keys
    return [] unless flow

    state = flow.state_for(@result)
    flow.closing_requirements
        .select { |requirement| requirement.applies_to?(state, @custom_attributes) && blank_value?(requirement.attribute_key) }
        .map(&:attribute_key)
  end

  def account_missing_keys
    return [] unless account_config_enabled?

    configs.select { |config| required?(config) && blank_value?(config['key']) }
           .map { |config| config['key'] }
  end

  def account_config_enabled?
    @account.feature_enabled?('conversation_required_attributes') && configs.any?
  end

  def configs
    @configs ||= @account.normalized_required_attributes
  end

  def context
    @context ||= @custom_attributes.merge(SYSTEM_OUTCOME_FIELD => RESULT_TO_SYSTEM_VALUE[@result])
  end

  def required?(config)
    return true unless config['rule'] == 'conditional'

    expected = config['condition_value']
    # A half-configured conditional rule (no condition value) never requires the attribute.
    return false if expected.nil? || expected == '' || (expected.is_a?(Array) && expected.empty?)

    actual = context[config['condition_field']]
    expected.is_a?(Array) ? expected.include?(actual) : actual == expected
  end

  def blank_value?(key)
    value = @custom_attributes[key]
    value.nil? || value.to_s.strip.empty?
  end
end
