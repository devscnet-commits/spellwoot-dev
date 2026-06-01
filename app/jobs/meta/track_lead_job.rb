class Meta::TrackLeadJob < ApplicationJob
  queue_as :default

  def perform(conversation_id)
    conversation = Conversation.find_by(id: conversation_id)
    return unless conversation

    Meta::ConversionsApiService.track_lead(conversation)
  end
end
