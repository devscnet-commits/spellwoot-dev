# The AI follow-up cadence of a stage on one card (enqueued by Pipelines::AutomationSweepJob). A lock
# per conversation keeps two sweeps from sending the same attempt.
class Pipelines::AiFollowupRunJob < ApplicationJob
  queue_as :low

  LOCK_TTL = 2.minutes

  def perform(cadence_id, conversation_id)
    cadence = PipelineAiFollowup.find_by(id: cadence_id)
    conversation = Conversation.find_by(id: conversation_id)
    return if cadence.nil? || conversation.nil?

    lock = Redis::LockManager.new
    lock_key = "pipelines:ai_followup:conv:#{conversation_id}"
    return unless lock.lock(lock_key, LOCK_TTL)

    begin
      Pipelines::AiFollowupRunner.new(cadence, conversation).perform
    rescue StandardError => e
      Rails.logger.error "[Pipelines::AiFollowupRunJob] conv=#{conversation_id} #{e.class}: #{e.message}"
    ensure
      lock.unlock(lock_key)
    end
  end
end
