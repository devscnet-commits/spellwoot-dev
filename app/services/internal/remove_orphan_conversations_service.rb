class Internal::RemoveOrphanConversationsService
  def initialize(account: nil, days: nil)
    @account = account
    @days = days
  end

  def perform
    orphan_conversations = build_orphan_conversations_query
    total_deleted = 0

    Rails.logger.info '[RemoveOrphanConversationsService] Starting removal of orphan conversations'

    orphan_conversations.find_in_batches(batch_size: 1000) do |batch|
      conversation_ids = batch.map(&:id)
      Conversation.where(id: conversation_ids).destroy_all
      total_deleted += batch.size
      Rails.logger.info "[RemoveOrphanConversationsService] Deleted #{batch.size} orphan conversations (#{total_deleted} total)"
    end

    Rails.logger.info "[RemoveOrphanConversationsService] Completed. Total deleted: #{total_deleted}"
    total_deleted
  end

  private

  def build_orphan_conversations_query
    base = @account ? @account.conversations : Conversation.all
    # `days` is an optional bound for ad-hoc runs. It used to default to 1, so an orphan was
    # only collected while its last activity stayed inside a 24h window — anything older (or
    # with no last_activity_at at all) was skipped on every subsequent run and stayed in the
    # agent's inbox forever.
    base = base.where('conversations.last_activity_at > ?', @days.days.ago) if @days
    base = base.left_outer_joins(:contact, :inbox)

    # Find conversations whose associated contact or inbox record is missing
    base.where(contacts: { id: nil }).or(base.where(inboxes: { id: nil }))
  end
end
