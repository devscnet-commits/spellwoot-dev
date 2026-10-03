# Puts the still-open conversations of the teams following a pipeline on its board (entry stage),
# e.g. right after the stages are configured or a team switches flows. No automations run: an
# existing backlog must not get a burst of "on enter" messages.
class Pipelines::BackfillJob < ApplicationJob
  queue_as :low

  def perform(flow_id)
    flow = OperationalFlow.find_by(id: flow_id)
    stage = flow&.active ? flow.default_stage : nil
    return if stage.nil?

    candidates(flow).find_each do |conversation|
      next unless Conversations::FlowResolver.new(conversation: conversation).flow&.id == flow.id

      Pipelines::StageMover.new(conversation: conversation, stage: stage, source: 'backfill').perform
    end
  end

  private

  def candidates(flow)
    team_ids = flow.teams.pluck(:id)
    return Conversation.none if team_ids.empty?

    scope = flow.account.conversations.where(pipeline_stage_id: nil, group_chat: false, result: :none, status: %i[open pending snoozed])
    member_ids = TeamMember.where(team_id: team_ids).select(:user_id)
    scope.where(team_id: team_ids).or(scope.where(assignee_id: member_ids))
  end
end
