# Decides whether a stage automation may run for a conversation: every condition must match
# (match_type all = E) or at least one (any = OU); no condition means it always runs.
# A condition is { attribute:, operator:, value:, attribute_key: } where attribute is one of
# PipelineAutomation::CONDITION_ATTRIBUTES (attribute_key names the custom attribute) and operator is
# equal_to / not_equal_to / is_present / is_not_present / greater_than / less_than.
class Pipelines::ConditionEvaluator
  def initialize(conversation, conditions, match_type: 'all')
    @conversation = conversation
    @conditions = Array(conditions).map { |condition| condition.to_h.with_indifferent_access }
    @match_type = match_type.to_s
  end

  def match?
    return true if @conditions.empty?
    return @conditions.any? { |condition| condition_match?(condition) } if @match_type == 'any'

    @conditions.all? { |condition| condition_match?(condition) }
  end

  private

  def condition_match?(condition)
    actual = actual_value(condition)
    expected = condition[:value]

    case condition[:operator].to_s
    when 'is_present' then present_value?(actual)
    when 'is_not_present' then !present_value?(actual)
    when 'not_equal_to' then !equal?(actual, expected)
    when 'greater_than' then compare(actual, expected) { |left, right| left > right }
    when 'less_than' then compare(actual, expected) { |left, right| left < right }
    else equal?(actual, expected)
    end
  end

  READERS = {
    'label' => :cached_label_list_array, 'priority' => :priority, 'team_id' => :team_id, 'assignee_id' => :assignee_id,
    'sla' => :pipeline_sla_status, 'temperature' => :temperature, 'status' => :status
  }.freeze

  def actual_value(condition)
    attribute = condition[:attribute].to_s
    return @conversation.custom_attributes.to_h[condition[:attribute_key].to_s] if attribute == 'custom_attribute'

    READERS[attribute] && @conversation.public_send(READERS[attribute])
  end

  def present_value?(value)
    value.is_a?(Array) ? value.any? : value.to_s.strip.present?
  end

  # Labels are a list: "equal to X" means the conversation carries label X.
  def equal?(actual, expected)
    expected_values = Array(expected).map { |value| value.to_s.strip.downcase }
    actual_values = Array(actual).map { |value| value.to_s.strip.downcase }
    actual_values.intersect?(expected_values)
  end

  def compare(actual, expected)
    return false unless present_value?(actual) && present_value?(expected)

    yield OperationalFlow.parse_amount(actual), OperationalFlow.parse_amount(expected)
  end
end
