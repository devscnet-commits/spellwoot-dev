# When a time-based stage automation is due for a card and the anchor that makes its run unique:
#   time_in_stage  due delay_minutes after the card entered the stage; anchor = the stage entry
#   inactivity     due delay_minutes after the last message (or the stage entry, if later), when the
#                  last message came from the expected side; anchor = start of the current silence
#                  (the customer's last message or the stage entry), so it runs once per silence
# Runs that would have been due before the automation existed are skipped: creating a rule never
# fires it at once on the whole backlog.
class Pipelines::AutomationSchedule
  Snapshot = Struct.new(:conversation_id, :entered_at, :last_at, :last_incoming, :last_in_at, keyword_init: true)

  INACTIVITY_STATUSES = [Conversation.statuses[:open], Conversation.statuses[:pending]].freeze

  def initialize(automation)
    @automation = automation
    @delay = automation.delay_minutes.to_i.minutes
  end

  # [[conversation_id, anchor_at], ...] due now and not run yet.
  def due_runs
    due = snapshots(base_scope).filter_map do |snapshot|
      anchor = anchor_for(snapshot)
      [snapshot.conversation_id, anchor] if anchor
    end
    filter_pending(due)
  end

  # Re-check for one card right before running (a message may have arrived since the sweep).
  def due_anchor(conversation)
    snapshot = snapshots(Conversation.where(id: conversation.id)).first
    snapshot && anchor_for(snapshot)
  end

  private

  def base_scope
    scope = Conversation.where(pipeline_stage_id: @automation.resolution_state_id)
    scope = scope.where(status: INACTIVITY_STATUSES) if inactivity?
    scope
  end

  def inactivity?
    @automation.trigger_type == 'inactivity'
  end

  def anchor_for(snapshot)
    return if snapshot.entered_at.nil?
    return time_in_stage_anchor(snapshot) unless inactivity?

    silence_from = [snapshot.last_at, snapshot.entered_at].compact.max
    return unless sender_match?(snapshot) && due?(silence_from + @delay)

    [snapshot.last_in_at, snapshot.entered_at].compact.max
  end

  def time_in_stage_anchor(snapshot)
    snapshot.entered_at if due?(snapshot.entered_at + @delay)
  end

  def due?(due_at)
    due_at.between?(@automation.created_at, Time.current)
  end

  def sender_match?(snapshot)
    case @automation.inactivity_sender
    when 'contact' then snapshot.last_incoming == true
    when 'agent' then snapshot.last_incoming == false
    else true
    end
  end

  def snapshots(scope)
    unless inactivity?
      return scope.pluck(:id, :pipeline_stage_entered_at).map { |id, entered| Snapshot.new(conversation_id: id, entered_at: entered) }
    end

    scope.joins(last_message_join).joins(last_incoming_join)
         .pluck(Arel.sql('conversations.id, conversations.pipeline_stage_entered_at, lm.created_at, lm.message_type, li.created_at'))
         .map do |id, entered, last_at, last_type, last_in_at|
      Snapshot.new(conversation_id: id, entered_at: entered, last_at: last_at,
                   last_incoming: last_type.nil? ? nil : last_type == Message.message_types[:incoming], last_in_at: last_in_at)
    end
  end

  def last_message_join
    <<~SQL.squish
      LEFT JOIN LATERAL (SELECT m.created_at, m.message_type FROM messages m
        WHERE m.conversation_id = conversations.id AND m.private = false AND m.message_type IN (#{chat_types})
        ORDER BY m.created_at DESC LIMIT 1) lm ON true
    SQL
  end

  def last_incoming_join
    <<~SQL.squish
      LEFT JOIN LATERAL (SELECT m.created_at FROM messages m
        WHERE m.conversation_id = conversations.id AND m.message_type = #{Message.message_types[:incoming]}
        ORDER BY m.created_at DESC LIMIT 1) li ON true
    SQL
  end

  def chat_types
    Message.message_types.values_at(:incoming, :outgoing).join(',')
  end

  # Drops what already ran for the same anchor.
  def filter_pending(due)
    return due if due.empty?

    done = PipelineAutomationRun.where(pipeline_automation_id: @automation.id, conversation_id: due.map(&:first))
                                .pluck(:conversation_id, :anchor_at).to_set { |conversation_id, anchor| [conversation_id, anchor.to_i] }
    due.reject { |conversation_id, anchor| done.include?([conversation_id, anchor.to_i]) }
  end
end
