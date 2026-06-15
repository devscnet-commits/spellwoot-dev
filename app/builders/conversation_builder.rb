class ConversationBuilder
  pattr_initialize [:params!, :contact_inbox!]

  def perform
    look_up_exising_conversation || create_new_conversation
  end

  private

  def look_up_exising_conversation
    return @contact_inbox.conversations.last if @contact_inbox.inbox.lock_to_single_conversation?

    reopenable_conversation_within_window
  end

  # When the inbox is NOT locked to a single conversation, a new message normally creates a
  # brand-new conversation. But if a reopen window (in hours) is configured, the last resolved
  # conversation is reused (and thus reopened) when it was resolved within that window — so a
  # quick follow-up continues the same thread instead of spawning a new one. Outside the window
  # (or when no window is set) this returns nil and a new conversation is created.
  def reopenable_conversation_within_window
    hours = @contact_inbox.inbox.reopen_window_hours.to_i
    return nil unless hours.positive?

    last_conversation = @contact_inbox.conversations.last
    return nil unless last_conversation&.resolved?

    reference = last_conversation.last_activity_at || last_conversation.updated_at
    last_conversation if reference.present? && reference >= hours.hours.ago
  end

  def create_new_conversation
    ::Conversation.create!(conversation_params)
  end

  def conversation_params
    additional_attributes = params[:additional_attributes]&.permit! || {}
    custom_attributes = params[:custom_attributes]&.permit! || {}
    status = params[:status].present? ? { status: params[:status] } : {}

    # TODO: temporary fallback for the old bot status in conversation, we will remove after couple of releases
    # commenting this out to see if there are any errors, if not we can remove this in subsequent releases
    # status = { status: 'pending' } if status[:status] == 'bot'
    {
      account_id: @contact_inbox.inbox.account_id,
      inbox_id: @contact_inbox.inbox_id,
      contact_id: @contact_inbox.contact_id,
      contact_inbox_id: @contact_inbox.id,
      additional_attributes: additional_attributes,
      custom_attributes: custom_attributes,
      snoozed_until: params[:snoozed_until],
      assignee_id: params[:assignee_id],
      team_id: params[:team_id]
    }.merge(status)
  end
end
