# Resolves which OperationalFlow (Closing Flow) applies to a conversation. A conversation already
# on a pipeline board keeps that pipeline's flow. Otherwise teams carry the flow: the
# conversation's assigned team decides; without a team, the (single) team of the assignee decides;
# for unassigned conversations, the team of the agent acting right now decides — whoever attends,
# their flow applies. Returns the flow only when it is active.
class Conversations::FlowResolver
  def initialize(conversation:, user: nil)
    @conversation = conversation
    @user = user
  end

  def flow
    resolved = stage_flow
    resolved = team_flow || assignee_team_flow || acting_user_team_flow unless resolved&.active
    resolved if resolved&.active
  end

  private

  def stage_flow
    @conversation.pipeline_stage&.operational_flow
  end

  def team_flow
    @conversation.team&.operational_flow
  end

  def assignee_team_flow
    team_flow_for(@conversation.assignee)
  end

  def acting_user_team_flow
    team_flow_for(@user)
  end

  def team_flow_for(user)
    return nil unless user.is_a?(User)

    user.teams.where(account_id: @conversation.account_id).order(:id).first&.operational_flow
  end
end
