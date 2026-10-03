# Moves a conversation (kanban card) to a pipeline stage: updates the card and records the move
# for the reports, in one transaction. The activity line in the conversation and the stage's
# "on enter" automations fire from ConversationStageEvent once the move is committed, so a
# caller that wraps the move in its own transaction (CardMoveService) never leaves a phantom
# activity or a job for a move that rolled back. Checking the stage requirements and
# setting/clearing the result is up to the caller.
class Pipelines::StageMover
  def initialize(conversation:, stage:, user: nil, source: 'manual')
    @conversation = conversation
    @stage = stage
    @user = user.is_a?(User) ? user : nil
    @source = source
  end

  def perform
    return false if @stage.nil? || @conversation.pipeline_stage_id == @stage.id

    from_stage_id = @conversation.pipeline_stage_id
    ActiveRecord::Base.transaction do
      # The stage deadline (SLA) belongs to the stage being left.
      @conversation.update!(pipeline_stage_id: @stage.id, pipeline_stage_entered_at: Time.current, pipeline_sla_due_at: nil)
      ConversationStageEvent.create!(
        account_id: @conversation.account_id, conversation: @conversation, operational_flow_id: @stage.operational_flow_id,
        from_stage_id: from_stage_id, to_stage_id: @stage.id, user: @user, source: @source
      )
    end
    true
  end
end
