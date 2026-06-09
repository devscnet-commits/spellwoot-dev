# Validates that the custom attributes required before resolving a conversation are present.
# Requirements live entirely on the conversation's Closing Flow (resolved from the assignment rules
# / Caixa). A conversation without a flow has no requirements and resolves freely. The chosen
# resolution state decides which per-flow requirements apply (won/lost/custom, or only "always"
# requirements when resolving with no result).
class Conversations::RequiredAttributesValidator
  def initialize(conversation:, custom_attributes: nil, result: nil)
    @conversation = conversation
    @custom_attributes = (custom_attributes || conversation.custom_attributes || {}).with_indifferent_access
    @result = (result || conversation.result).to_s
  end

  def valid?
    missing_keys.empty?
  end

  def missing_keys
    return [] unless flow

    state = flow.state_for(@result)
    flow.closing_requirements
        .select { |requirement| requirement.applies_to?(state) && blank_value?(requirement.attribute_key) }
        .map(&:attribute_key)
  end

  private

  def flow
    return @flow if @flow_loaded

    @flow_loaded = true
    @flow = @conversation.operational_flow
  end

  def blank_value?(key)
    value = @custom_attributes[key]
    value.nil? || value.to_s.strip.empty?
  end
end
