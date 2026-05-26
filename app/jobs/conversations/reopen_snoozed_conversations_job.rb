class Conversations::ReopenSnoozedConversationsJob < ApplicationJob
  queue_as :low

  def perform
    #Conversation.where(status: :snoozed).find_each(batch_size: 100, &:open!)
  end
end

