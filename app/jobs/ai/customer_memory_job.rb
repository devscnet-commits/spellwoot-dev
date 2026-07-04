# Background: rebuilds one contact's persistent memory from a just-resolved conversation.
# Isolated (rescue) so a memory failure never affects the conversation lifecycle.
class Ai::CustomerMemoryJob < ApplicationJob
  queue_as :low

  def perform(conversation_id)
    conversation = Conversation.find_by(id: conversation_id)
    return if conversation.blank? || conversation.contact_id.blank?

    Ai::CustomerMemoryUpdater.new(conversation: conversation).update
  rescue StandardError => e
    Rails.logger.error "[Ai::CustomerMemoryJob] conv=#{conversation_id} #{e.class}: #{e.message}"
  end
end
