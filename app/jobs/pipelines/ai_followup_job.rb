# Manual "Follow-up IA" from a kanban card (the cadence of a stage runs through its automations).
class Pipelines::AiFollowupJob < ApplicationJob
  queue_as :medium

  def perform(conversation_id, agent_id, prompt, user_id = nil)
    conversation = Conversation.find_by(id: conversation_id)
    agent = Ai::Agent.find_by(id: agent_id)
    return if conversation.nil? || agent.nil?

    Pipelines::AiFollowupService.new(conversation: conversation, agent: agent, prompt: prompt, user: User.find_by(id: user_id)).perform!
  rescue Pipelines::AiFollowupService::Error => e
    Rails.logger.info "[Pipelines::AiFollowupJob] conv=#{conversation_id} skipped: #{e.message}"
  end
end
