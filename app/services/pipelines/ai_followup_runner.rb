# Runs the AI follow-up cadence of a stage on one card. Same decision as the AI agent's own
# follow-up (Ai::FollowupConversationJob), applied whoever owns the card:
#   1. the silence starts at the customer's last message (or the stage entry, if later); silences
#      that started before the cadence was activated are left alone (no burst on the backlog);
#   2. the behavior for the moment (inbox hours / outside / custom windows) decides the attempts;
#   3. attempt N goes out delay_minutes after attempt N-1 (the first one after the silence started),
#      if who sent the last message matches the attempt; the chosen AI agent writes it and the AI
#      takes the conversation back (Pipelines::AiFollowupService);
#   4. after the last attempt and inactivity_minutes more of silence, the no-response action runs.
# Everything is recorded as ai_events in the conversation, so each attempt/action happens once per
# silence; the customer's next message restarts the cadence.
class Pipelines::AiFollowupRunner
  include Ai::FollowupContext

  SENT_EVENT = 'pipeline_followup.sent'.freeze
  FAILED_EVENT = 'pipeline_followup.failed'.freeze
  ACTION_EVENT = 'pipeline_followup.action'.freeze
  RETRY_AFTER_FAILURE = 15.minutes

  def initialize(cadence, conversation)
    @cadence = cadence
    @conversation = conversation
    @account = conversation.account
  end

  def perform
    reason = skip_reason
    return log_skip(reason) if reason

    behavior = active_behavior(@cadence.normalized_behaviors, @conversation.inbox)
    return log_skip('no_matching_behavior_for_now') if behavior.nil?

    attempts = active_attempts(behavior)
    sent = sent_events
    sent.size < attempts.size ? maybe_send_attempt(attempts[sent.size], sent) : maybe_run_action(behavior, sent)
  end

  private

  def skip_reason
    card_skip_reason || silence_skip_reason
  end

  def card_skip_reason
    return 'not_in_stage' unless @cadence.active && @conversation.pipeline_stage_id == @cadence.resolution_state_id
    return 'not_open' unless @conversation.status.in?(%w[open pending])
    return 'group_conversation' if @conversation.group_chat?

    'ai_disabled_attribute' if ActiveModel::Type::Boolean.new.cast(@conversation.custom_attributes.to_h['desativa_ia'])
  end

  def silence_skip_reason
    return 'no_messages' if last_message.nil?
    return 'silence_before_activation' if silence_started_at < @cadence.activated_at
    return 'already_acted_this_silence' if acted?

    'recent_failure' if failed_recently?
  end

  def active_attempts(behavior)
    Array(behavior[:attempts]).map { |attempt| attempt.to_h.with_indifferent_access }.reject { |attempt| attempt[:active] == false }
  end

  def last_message
    @last_message ||= @conversation.messages.where(message_type: %i[incoming outgoing], private: false).reorder(created_at: :desc).first
  end

  def last_incoming_at
    @last_incoming_at ||= @conversation.messages.incoming.maximum(:created_at)
  end

  def silence_started_at
    @silence_started_at ||= [last_incoming_at, @conversation.pipeline_stage_entered_at].compact.max
  end

  def events(type)
    Ai::Event.where(conversation_id: @conversation.id, event_type: type).where('created_at > ?', silence_started_at)
             .where("payload ->> 'cadence_id' = ?", @cadence.id.to_s)
  end

  def sent_events
    events(SENT_EVENT).order(:created_at).to_a
  end

  def acted?
    events(ACTION_EVENT).exists?
  end

  def failed_recently?
    events(FAILED_EVENT).exists?(['created_at > ?', RETRY_AFTER_FAILURE.ago])
  end

  # --- attempts ----------------------------------------------------------------------------------

  def maybe_send_attempt(attempt, sent)
    index = sent.size + 1
    reason = attempt_skip_reason(attempt, sent)
    return log_skip(reason, index: index) if reason

    agent = Ai::Agent.find_by(id: attempt[:ai_agent_id], account_id: @account.id)
    return log_skip('agent_missing', index: index) if agent.nil?

    Pipelines::AiFollowupService.new(conversation: @conversation, agent: agent, prompt: attempt[:prompt],
                                     event_payload: { cadence_id: @cadence.id, index: index }).perform!
    Rails.logger.info "[Pipelines::AiFollowupRunner] conv=#{@conversation.id} cadence=#{@cadence.id} sent index=#{index}"
  rescue Pipelines::AiFollowupService::Error => e
    emit(FAILED_EVENT, { cadence_id: @cadence.id, index: index, reason: e.message })
    log_skip("attempt_#{e.message}", index: index)
  end

  def attempt_skip_reason(attempt, sent)
    since = sent.last&.created_at || silence_started_at
    return 'delay_not_elapsed' if since > attempt[:delay_minutes].to_i.minutes.ago

    'sender_mismatch' unless sender_match?(attempt[:inactivity_sender])
  end

  # The sent attempts after the pipeline reactivated the AI are outgoing messages without a sender,
  # so after the first attempt "the company sent the last message" holds for the next ones.
  def sender_match?(expected)
    case expected.to_s
    when 'contact' then last_message.incoming?
    when 'agent' then last_message.outgoing?
    else true
    end
  end

  # --- after the last attempt --------------------------------------------------------------------

  def maybe_run_action(behavior, sent)
    since = sent.last&.created_at || silence_started_at
    return log_skip('inactivity_not_elapsed') if since > @cadence.inactivity_minutes.to_i.minutes.ago

    action = behavior[:no_response_action].presence || 'assign'
    return log_skip('waiting_business_hours') if action == 'wait_business_hours' && !business_hours_open?(@conversation.inbox)

    run_action(action, behavior)
    emit(ACTION_EVENT, { cadence_id: @cadence.id, action: action })
    Rails.logger.info "[Pipelines::AiFollowupRunner] conv=#{@conversation.id} cadence=#{@cadence.id} action=#{action}"
  end

  def run_action(action, behavior)
    case action
    when 'finalize' then finalize
    when 'discard' then @conversation.update!(status: :resolved)
    when 'wait' then nil
    when 'move_stage' then move_stage(behavior[:no_response_stage_id])
    else assign_human
    end
  end

  def finalize
    message = @cadence.close_message.to_s.strip
    Messages::MessageBuilder.new(nil, @conversation, { content: message, private: false }).perform if message.present?
    @conversation.update!(status: :resolved)
  end

  # The AI steps aside; a card with an owner goes back to them, an orphan one is assigned through
  # the agent's handoff rules.
  def assign_human
    @conversation.update!(additional_attributes: @conversation.additional_attributes.to_h.merge('ai_handoff' => true))
    return if @conversation.assignee_id.present?

    agent = Ai::Agent.find_by(id: @cadence.first_attempt&.dig(:ai_agent_id), account_id: @account.id)
    return if agent.nil?

    coordinator = Ai::HandoffCoordinator.new(conversation: @conversation, account: @account, agent: agent, message: nil)
    coordinator.assign_human(coordinator.human_team_id({}), reason: 'pipeline_followup_timeout')
  end

  def move_stage(stage_id)
    stage = @cadence.operational_flow.resolution_states.find_by(id: stage_id)
    return if stage.nil?

    Pipelines::CardMoveService.new(conversation: @conversation, stage: stage, source: 'automation').perform
  end

  def emit(type, payload)
    Ai::Event.create!(account_id: @account.id, conversation_id: @conversation.id, event_type: type, payload: payload)
  end

  def log_skip(reason, **details)
    extra = details.map { |key, value| "#{key}=#{value.inspect}" }.join(' ')
    Rails.logger.info "[Pipelines::AiFollowupRunner] conv=#{@conversation.id} cadence=#{@cadence.id} skip=#{reason} #{extra}".strip
    nil
  end
end
