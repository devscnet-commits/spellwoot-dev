# Runs the "on enter" automations of the stage a card just entered, in their configured order.
class Pipelines::StageEnteredJob < ApplicationJob
  queue_as :medium

  def perform(conversation_id, stage_id)
    conversation = Conversation.find_by(id: conversation_id)
    return if conversation.nil? || conversation.pipeline_stage_id != stage_id
    return unless conversation.account.feature_enabled?('crm_automations')

    PipelineAutomation.active.where(resolution_state_id: stage_id, trigger_type: 'stage_entered')
                      .order(:sort_order, :id).each do |automation|
      conversation.reload
      Pipelines::AutomationRunner.new(automation, conversation, conversation.pipeline_stage_entered_at).perform
    end
  end
end
