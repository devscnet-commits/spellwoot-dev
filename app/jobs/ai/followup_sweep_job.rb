# Periodic follow-up sweep. The follow-up ONLY resumes a quiet conversation; delivery decisions
# live in each behavior's `no_response_action` (the inactivity grace is global, in close_rules).
#
# department.follow_up shape (jsonb):
#   { "instructions": "...",
#     "behaviors": [ { "context": "inbox_hours" | "outside_hours" | "custom",
#                      "windows": [ { "start": "08:00", "end": "18:00" } ],   # custom only
#                      "attempts": [ { "delay_minutes": 10, "message": "..." }, ... ],
#                      "no_response_action": "assign" | "finalize" | "discard" | "wait" | "wait_business_hours" } ] }
#
# department.close_rules: { "message": "...", "inactivity_minutes": 30,
#                           "no_followup_actions": ["transfer_ai" | "transfer_human" | "wait" | "finalize"] }
#
# Rules: 1 behavior per fixed context (inbox_hours/outside_hours), custom unlimited. The active
# behavior is the first whose context matches NOW. After the last attempt + the inactivity window,
# the behavior's action fires once (idempotent via a 'followup.action' event).
#
# Fallback: when the department has NO follow-up behaviors at all, the inactivity window still
# applies — once the customer is quiet for close_rules.inactivity_minutes, the first decision in
# no_followup_actions (order = priority) fires once (same 'followup.action' idempotency).
# 'transfer_ai' re-runs Ai::GatewayRunJob on the customer's last message so the AI takes another
# turn; 'transfer_human' unassigns; 'finalize' sends close_rules.message + resolves; 'wait' holds.
class Ai::FollowupSweepJob < ApplicationJob
  queue_as :low

  DEFAULT_INACTIVITY = 30

  def perform
    Ai::AgentInbox.live.includes(agent: :account).find_each do |binding|
      next unless binding.agent.account&.feature_enabled?('ai_core')

      department = binding.agent.departments.active.first
      next if department.nil?

      behaviors = Array(department.follow_up.to_h['behaviors'])
      fallback = fallback_actions(department)
      next if behaviors.empty? && fallback.empty?

      sweep(binding, department, behaviors, fallback)
    end
  end

  private

  def sweep(binding, department, behaviors, fallback)
    account_id = binding.agent.account_id
    inbox = ::Inbox.find_by(id: binding.inbox_id)
    return if inbox.nil?

    Conversation.where(inbox_id: binding.inbox_id, status: :open).find_each do |conversation|
      process(binding, department, behaviors, fallback, inbox, conversation, account_id)
    rescue StandardError => e
      Rails.logger.error "[Ai::FollowupSweepJob] conv=#{conversation.id} #{e.class}: #{e.message}"
    end
  end

  def process(binding, department, behaviors, fallback, inbox, conversation, account_id)
    return unless awaiting_customer?(conversation)
    return if conversation.assignee_id.present? # a human already took over
    # Já entregue a um humano (handoff): a IA/follow-up saem de cena — não retomam nem finalizam.
    return if conversation.additional_attributes.to_h['ai_handoff']
    return if acted?(conversation) # terminal action already fired in this silence

    # No follow-up configured: skip straight to the no-follow-up decision (close_rules).
    if behaviors.empty?
      maybe_run_fallback(department, fallback, inbox, conversation, account_id)
      return
    end

    behavior = active_behavior(behaviors, inbox)
    return if behavior.nil? # no behavior applies at this time

    attempts = Array(behavior['attempts'])
    sent = followups_since_incoming(conversation)

    if sent.count < attempts.size
      maybe_send_attempt(binding, department, attempts, sent, conversation, account_id)
    else
      maybe_run_action(department, behavior, inbox, conversation, account_id, sent)
    end
  end

  # --- Sending the next attempt ------------------------------------------------

  def maybe_send_attempt(binding, department, attempts, sent, conversation, account_id)
    index = sent.count
    delay = attempts[index]['delay_minutes'].to_i
    last_at = sent.maximum(:created_at) || last_incoming_at(conversation) || conversation.last_activity_at
    return if last_at && last_at > delay.minutes.ago # not time yet

    message = effective_message(attempts, index)
    return if message.blank? # nothing to say (all messages empty up to here)

    if Ai::ReplyPolicy.allowed?(mode: binding.mode, department: department, conversation: conversation)
      Messages::MessageBuilder.new(nil, conversation, { content: message, private: false }).perform
      emit(account_id, conversation.id, 'followup.sent', { index: index + 1, chars: message.length })
    else
      reason = Ai::ReplyPolicy.skip_reason(mode: binding.mode, department: department, conversation: conversation)
      emit(account_id, conversation.id, 'followup.intended', { index: index + 1, executed: false, reason: reason })
    end
  end

  # Empty messages reuse the last non-empty message of the earlier attempts.
  def effective_message(attempts, index)
    attempts[0..index].reverse_each do |a|
      msg = a['message'].to_s.strip
      return msg if msg.present?
    end
    ''
  end

  # --- Action after the last attempt + inactivity window -----------------------

  def maybe_run_action(department, behavior, inbox, conversation, account_id, sent)
    inactivity = inactivity_minutes(department)
    last_send = sent.maximum(:created_at)
    return if last_send && last_send > inactivity.minutes.ago # still inside the inactivity window

    run_action(behavior['no_response_action'].to_s, department, inbox, conversation, account_id)
  end

  def run_action(action, department, inbox, conversation, account_id)
    case action
    when 'finalize'
      send_close_message(department, conversation)
      conversation.update!(status: :resolved)
      record_action(conversation, account_id, 'finalize')
    when 'discard'
      conversation.update!(status: :resolved)
      record_action(conversation, account_id, 'discard')
    when 'wait'
      record_action(conversation, account_id, 'wait') # hold; recorded so we stop re-evaluating
    when 'wait_business_hours'
      # Hold until business hours, then assign to a human.
      if business_hours_open?(inbox)
        assign_to_human(conversation)
        record_action(conversation, account_id, 'assign', via: 'wait_business_hours')
      end
    else # 'assign' (default)
      assign_to_human(conversation)
      record_action(conversation, account_id, 'assign')
    end
  end

  # --- Fallback: no follow-up configured (close_rules.no_followup_actions) ------

  # Ordered list of decisions for when the inactivity window passes and there is no
  # follow-up to fire. Order = priority; the first one wins.
  def fallback_actions(department)
    Array(department.close_rules.to_h['no_followup_actions']).map(&:to_s).select(&:present?)
  end

  def maybe_run_fallback(department, fallback, inbox, conversation, account_id)
    action = fallback.first
    return if action.blank?

    quiet_at = quiet_since(conversation)
    inactivity = inactivity_minutes(department)
    return if quiet_at && quiet_at > inactivity.minutes.ago # still inside the inactivity window

    run_fallback_action(action, department, inbox, conversation, account_id)
  end

  def run_fallback_action(action, department, inbox, conversation, account_id)
    case action
    when 'finalize'
      send_close_message(department, conversation)
      conversation.update!(status: :resolved)
      record_action(conversation, account_id, 'finalize', via: 'no_followup')
    when 'transfer_human'
      assign_to_human(conversation)
      record_action(conversation, account_id, 'transfer_human', via: 'no_followup')
    when 'transfer_ai'
      # Re-engage the AI proactively: re-run the Gateway anchored on the customer's last
      # message so the AI takes another turn (reply/tool/handoff per its own decision).
      # The Gateway resolves the binding/team routing/mode and respects reply_scope and
      # max_replies on its own.
      reengage_ai(conversation)
      record_action(conversation, account_id, 'transfer_ai', via: 'no_followup')
    else # 'wait'
      record_action(conversation, account_id, 'wait', via: 'no_followup')
    end
  end

  def assign_to_human(conversation)
    conversation.update!(assignee_id: nil) if conversation.assignee_id.present?
  end

  # Proactively hand the turn back to the AI by re-running the Gateway on the customer's
  # last incoming message. No-op when the customer never wrote (nothing to anchor on).
  def reengage_ai(conversation)
    anchor = conversation.messages.incoming.order(:created_at).last
    return if anchor.nil?

    Ai::GatewayRunJob.perform_later(anchor.id)
  end

  def send_close_message(department, conversation)
    message = department.close_rules.to_h['message'].to_s.strip
    return if message.blank?

    Messages::MessageBuilder.new(nil, conversation, { content: message, private: false }).perform
  end

  def record_action(conversation, account_id, action, via: nil)
    emit(account_id, conversation.id, 'followup.action', { action: action, via: via }.compact)
  end

  # --- Context / business hours ------------------------------------------------

  # First behavior whose context matches NOW (custom may be several; order decides).
  def active_behavior(behaviors, inbox)
    inside = business_hours_open?(inbox)
    behaviors.find do |b|
      case b['context'].to_s
      when 'inbox_hours' then inside
      when 'outside_hours' then !inside
      when 'custom' then within_custom_window?(b['windows'], inbox)
      else false
      end
    end
  end

  def business_hours_open?(inbox)
    inbox.respond_to?(:available_now?) ? inbox.available_now? : true
  rescue StandardError
    true
  end

  def within_custom_window?(windows, inbox)
    return false if windows.blank?

    now = current_hm(inbox)
    Array(windows).any? do |w|
      start_at = w['start'].to_s
      end_at = w['end'].to_s
      next false if start_at.blank? || end_at.blank?

      start_at <= end_at ? now.between?(start_at, end_at) : (now >= start_at || now <= end_at)
    end
  end

  def current_hm(inbox)
    tz = inbox.respond_to?(:timezone) ? inbox.timezone : nil
    (tz.present? ? Time.current.in_time_zone(tz) : Time.current).strftime('%H:%M')
  rescue StandardError
    Time.current.strftime('%H:%M')
  end

  def inactivity_minutes(department)
    minutes = department.close_rules.to_h['inactivity_minutes'].to_i
    minutes.positive? ? minutes : DEFAULT_INACTIVITY
  end

  # --- Conversation state helpers ----------------------------------------------

  # We only resume when the last real message was ours (the customer went quiet).
  def awaiting_customer?(conversation)
    last = conversation.messages.where(message_type: %i[incoming outgoing]).order(:created_at).last
    last&.outgoing?
  end

  def last_incoming_at(conversation)
    conversation.messages.incoming.maximum(:created_at)
  end

  # When the customer went quiet: the last real message (which, given awaiting_customer?,
  # is ours). Used as the inactivity reference for the no-follow-up fallback.
  def quiet_since(conversation)
    conversation.messages.where(message_type: %i[incoming outgoing]).maximum(:created_at) ||
      conversation.last_activity_at
  end

  # Follow-ups already sent in this silence (since the customer's last incoming message).
  def followups_since_incoming(conversation)
    scope = Ai::Event.where(conversation_id: conversation.id, event_type: 'followup.sent')
    incoming_at = last_incoming_at(conversation)
    incoming_at ? scope.where('created_at > ?', incoming_at) : scope
  end

  # A terminal action already fired in this silence — don't act again.
  def acted?(conversation)
    scope = Ai::Event.where(conversation_id: conversation.id, event_type: 'followup.action')
    incoming_at = last_incoming_at(conversation)
    incoming_at ? scope.where('created_at > ?', incoming_at).exists? : scope.exists?
  end

  def emit(account_id, conversation_id, type, payload)
    Ai::Event.create!(account_id: account_id, conversation_id: conversation_id, event_type: type, payload: payload)
  end
end
