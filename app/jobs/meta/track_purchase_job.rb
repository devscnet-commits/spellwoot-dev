class Meta::TrackPurchaseJob < ApplicationJob
  queue_as :default

  def perform(conversation_id, value: nil, event_name: 'Purchase', event_id: nil)
    conversation = Conversation.find_by(id: conversation_id)
    return unless conversation

    Meta::ConversionsApiService.track_purchase(conversation, value: value, event_name: event_name, event_id: event_id)
  end
end
