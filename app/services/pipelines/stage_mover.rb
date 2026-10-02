# Moves a conversation (kanban card) to a pipeline stage: records the move for the reports, leaves
# an activity line in the conversation and fires the stage's "on enter" automations. Checking the
# stage requirements and setting/clearing the result is up to the caller.
class Pipelines::StageMover
  def initialize(conversation:, stage:, user: nil, source: 'manual', run_automations: true)
    @conversation = conversation
    @stage = stage
    @user = user.is_a?(User) ? user : nil
    @source = source
    @run_automations = run_automations
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
    create_activity unless @source == 'backfill'
    Pipelines::StageEnteredJob.perform_later(@conversation.id, @stage.id) if @run_automations
    true
  end

  private

  def create_activity
    content = I18n.with_locale(@conversation.account.locale) do
      if @user
        I18n.t('conversations.activity.pipeline.moved', user_name: @user.name, stage_name: @stage.display_label)
      else
        I18n.t('conversations.activity.pipeline.moved_by_system', stage_name: @stage.display_label)
      end
    end
    ::Conversations::ActivityMessageJob.perform_later(
      @conversation, { account_id: @conversation.account_id, inbox_id: @conversation.inbox_id, message_type: :activity, content: content }
    )
  end
end
