# Validates that the custom attributes required before resolving a conversation are present.
# When the conversation resolves under a Closing Flow, requirements come from that flow's
# closing_requirements (keyed on the chosen resolution state). For conversations without a flow
# it falls back to the legacy account-level configuration (settings.conversation_required_attributes).
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
    return flow_missing_keys if flow_requirements?

    legacy_missing_keys
  end

  private

  def flow
    return @flow if @flow_loaded

    @flow_loaded = true
    @flow = @conversation.operational_flow
  end

  def flow_requirements?
    flow.present? && flow.closing_requirements.any?
  end

  def flow_missing_keys
    state = flow.state_for(@result)
    flow.closing_requirements
        .select { |req| req.applies_to?(state) && blank_value?(req.attribute_key) }
        .map(&:attribute_key)
  end

  # --- Legacy account-level configuration (conversations without a closing flow) ---

  def legacy_missing_keys
    return [] unless legacy_enabled?

    configs.select { |config| required?(config) && blank_value?(config['key']) }
           .map { |config| config['key'] }
  end

  def legacy_enabled?
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
    return false if expected.nil? || expected == '' || (expected.is_a?(Array) && expected.empty?)

    actual = context[config['condition_field']]
    expected.is_a?(Array) ? expected.include?(actual) : actual == expected
  end

  def blank_value?(key)
    value = @custom_attributes[key]
    value.nil? || value.to_s.strip.empty?
  end
end
