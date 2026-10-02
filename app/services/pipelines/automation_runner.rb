# Runs one stage automation on one card, at most once per anchor (stage entry or start of the
# silence): the run row is claimed first through its unique index, then the card must still be in the
# stage (and, for time-based triggers, still be due), then the conditions decide whether the actions run.
class Pipelines::AutomationRunner
  def initialize(automation, conversation, anchor_at)
    @automation = automation
    @conversation = conversation
    @anchor_at = anchor_at
  end

  def perform
    return unless still_due?

    run = claim_run
    return if run.nil?

    unless Pipelines::ConditionEvaluator.new(@conversation, @automation.conditions, match_type: @automation.match_type).match?
      return run.update!(status: 'skipped')
    end

    errors = Pipelines::ActionService.new(@automation, @conversation).perform
    run.update!(status: errors.empty? ? 'completed' : 'failed', error: errors.join(' | ').truncate(250).presence)
  end

  private

  def still_due?
    return false unless @automation.active && @conversation.pipeline_stage_id == @automation.resolution_state_id
    return @conversation.pipeline_stage_entered_at.to_i == @anchor_at.to_i if @automation.trigger_type == 'stage_entered'

    Pipelines::AutomationSchedule.new(@automation).due_anchor(@conversation).to_i == @anchor_at.to_i
  end

  def claim_run
    PipelineAutomationRun.create!(pipeline_automation: @automation, conversation: @conversation, anchor_at: @anchor_at)
  rescue ActiveRecord::RecordNotUnique
    nil
  end
end
