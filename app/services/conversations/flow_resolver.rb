# Resolves which OperationalFlow (Closing Flow) applies to a conversation. Teams carry the
# flow: the conversation's assigned team decides; without a team, the assignee's (single)
# team decides; the caixa's flow is the fallback for dedicated channels. Returns the flow
# only when it is active.
class Conversations::FlowResolver
  def initialize(conversation:, user: nil)
    @conversation = conversation
    @user = user
  end

  def flow
    resolved = team_flow || assignee_team_flow || @conversation.inbox&.operational_flow
    resolved if resolved&.active
  end

  private

  def team_flow
    @conversation.team&.operational_flow
  end

  def assignee_team_flow
    assignee = @conversation.assignee
    return nil unless assignee.is_a?(User)

    assignee.teams.where(account_id: @conversation.account_id).order(:id).first&.operational_flow
  end
end
