class Meta::TrackPurchaseJob < ApplicationJob
  queue_as :default

  def perform(conversation_id, value: nil)
    conversation = Conversation.find_by(id: conversation_id)
    return unless conversation

    Meta::ConversionsApiService.track_purchase(conversation, value: value)
  end
end
