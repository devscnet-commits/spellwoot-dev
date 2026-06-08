# Backend mirror of the frontend `checkMissingAttributes` logic. Validates that the
# conversation custom attributes required by the account configuration are present before
# a conversation is resolved. Conditional rules can trigger on the system result field
# (__resultado_conversa__) derived from the conversation result.
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
    return [] unless enabled?

    configs.select { |config| required?(config) && blank_value?(config['key']) }
           .map { |config| config['key'] }
  end

  private

  def enabled?
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
