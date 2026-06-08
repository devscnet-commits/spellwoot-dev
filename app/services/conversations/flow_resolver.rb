# Resolves which OperationalFlow (Closing Flow) applies to a conversation, evaluating the
# account's FlowAssignmentRules by ascending priority (first match wins) against the closing
# context (role, inbox, team, origin). Falls back to the inbox's directly-attached flow for
# backward compatibility. Returns the flow only when it is active.
class Conversations::FlowResolver
  def initialize(conversation:, user: nil)
    @conversation = conversation
    @user = user
  end

  def flow
    resolved = matching_rule&.operational_flow || @conversation.inbox&.operational_flow
    resolved if resolved&.active
  end

  private

  def matching_rule
    return nil unless @conversation.account

    @conversation.account.flow_assignment_rules.ordered.find { |rule| rule.matches?(context) }
  end

  def context
    {
      inbox_id: @conversation.inbox_id,
      team_id: @conversation.team_id,
      role_id: effective_role_id,
      conversation_origin: conversation_origin
    }
  end

  def effective_role_id
    return nil unless @user.is_a?(User)

    @user.account_users.find_by(account_id: @conversation.account_id)&.custom_role_id
  end

  def conversation_origin
    (@conversation.additional_attributes || {})['conversation_origin']
  end
end
