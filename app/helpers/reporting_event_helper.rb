module ReportingEventHelper
  def business_hours(inbox, from, to)
    Inboxes::BusinessHoursCalculator.new(inbox: inbox).elapsed_seconds(from, to) || 0
  end

  def last_non_human_activity(conversation)
    # Try to get either a handoff or reopened event first
    # These will always take precedence over any other activity
    # Also, any of these events can happen at any time in the course of a conversation lifecycle.
    # So we pick the latest event
    event = ReportingEvent.where(
      conversation_id: conversation.id,
      name: %w[conversation_bot_handoff conversation_opened]
    ).order(event_end_time: :desc).first

    return event.event_end_time if event&.event_end_time

    # Fallback to bot resolved event
    # Because this will be closest to the most accurate activity instead of conversation.created_at
    bot_event = ReportingEvent.where(conversation_id: conversation.id, name: 'conversation_bot_resolved').last

    return bot_event.event_end_time if bot_event&.event_end_time

    # If no events found, return conversation creation time
    conversation.created_at
  end
end
