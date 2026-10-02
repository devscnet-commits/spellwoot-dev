class Pipelines::AutomationRunJob < ApplicationJob
  queue_as :medium

  def perform(automation_id, conversation_id, anchor_at)
    automation = PipelineAutomation.find_by(id: automation_id)
    conversation = Conversation.find_by(id: conversation_id)
    return if automation.nil? || conversation.nil?

    Pipelines::AutomationRunner.new(automation, conversation, Time.zone.parse(anchor_at)).perform
  end
end
