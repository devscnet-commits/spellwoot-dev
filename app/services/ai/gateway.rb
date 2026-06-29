# The AI Gateway — F1 happy-path, SHADOW only.
# Pipeline: message.received -> resolve_agent (caller) -> resolve_department -> assemble_context
#           -> retrieve_knowledge -> decide -> record ai_runs + ai_events.
# In shadow it NEVER replies, NEVER executes a tool, NEVER writes operational changes — it only
# records intention, runs and events.
class Ai::Gateway
  def initialize(message:, agent_inbox:, mode: nil, content_override: nil)
    @message = message
    @agent_inbox = agent_inbox
    @agent = agent_inbox.agent
    @conversation = message.conversation
    @account = message.account
    # mode may be downgraded by the caller (team routing): a non-owner agent observes (shadow).
    @mode = mode || agent_inbox.mode
    # When grouping, the caller passes the whole customer burst as the content to consider.
    @content_override = content_override
  end

  def run
    run_record = Ai::Run.create!(
      account_id: @account.id, conversation_id: @conversation.id, ai_agent_id: @agent.id,
      inbox_id: @message.inbox_id, run_type: 'decision', mode: @mode, status: 'running'
    )
    emit(run_record, 'message.received', { content: @message.content.to_s.first(500) })

    # Invisible worker: turn media (audio/image) into text the supervisor can use.
    media_text = Ai::Workers::MediaProcessor.process(@message)
    emit(run_record, 'media.preprocessed', { text: media_text }) if media_text.present?
    base_content = @content_override.presence || @message.content
    effective_content = [base_content, media_text].compact.join("\n").strip

    department, resolution = Ai::DepartmentResolver.resolve(
      agent: @agent, inbox_id: @message.inbox_id, message_content: effective_content
    )
    emit(run_record, 'department.resolved', { department_id: department&.id, name: department&.name, method: resolution })
    return finalize(run_record, 'no_department') unless department

    run_record.update!(ai_department_id: department.id)

    # Cap the customer input the model sees, to bound tokens per interaction (anti-abuse).
    max_input = department.behavior.to_h['max_input_chars'].to_i
    effective_content = effective_content.first(max_input) if max_input.positive?

    # Single gate for every outward action (reply, tools, transfer/resolve): the AI only acts when
    # this conversation is effectively live — i.e. live binding + auto_attendance on + within hours
    # + reply_scope all/canary-match. Otherwise it observes (records intention) only, so a live
    # binding piloted "behind canary" never touches non-canary conversations.
    @acts_live =
      Ai::ReplyPolicy.effective_reply_state(mode: @mode, department: department, conversation: @conversation) == :live

    knowledge = Ai::KnowledgeRetriever.retrieve(query: effective_content, account_id: @account.id)
    emit(run_record, 'knowledge.retrieved', { count: knowledge.size, preview: knowledge.first(2) })
    run_record.update!(knowledge_count: knowledge.size)

    memory = Ai::AgentMemory.find_by(conversation_id: @conversation.id, ai_agent_id: @agent.id)
    tools  = department.tools.active.to_a
    system_prompt = Ai::PromptCompiler.compile(
      agent: @agent, department: department, knowledge: knowledge, memory: memory, tools: tools
    )
    emit(run_record, 'context.assembled', { prompt_chars: system_prompt.length, tools: tools.map(&:name) })

    result = Ai::ModelRouter.decide(
      profile: @agent.operation_profile, system_prompt: system_prompt,
      user_message: build_user_message(effective_content), account_id: @account.id
    )
    run_record.update!(
      provider: result[:provider], model: result[:model],
      tokens_in: result[:tokens_in], tokens_out: result[:tokens_out],
      cost: result[:cost], latency_ms: result[:latency_ms],
      decision: result[:decision] || {}, status: result[:status],
      error_type: (result[:status] == 'error' ? 'provider_error' : nil)
    )
    emit(run_record, 'decision.made',
         { decision: result[:decision], cost: result[:cost], latency_ms: result[:latency_ms] },
         run_id: run_record.id)

    # Track which step the conversation is on so message grouping can use that step's delay.
    track_step(department, result[:decision] || {}) if @acts_live

    # Tool handling. SHADOW never executes — only records intention. LIVE runs the executor,
    # which executes the tool immediately (tools are autonomous).
    intended_tool = result.dig(:decision, 'tool')
    execution = nil
    if intended_tool.present?
      tool = department.tools.active.find_by(name: intended_tool['name'])
      if @acts_live && tool
        execution = Ai::ToolExecutor.new(
          tool: tool, input: intended_tool['input'], conversation: @conversation, mode: @mode, run: run_record
        ).perform
        emit(run_record, 'tool.executed',
             { tool: tool.name, status: execution.status, execution_id: execution.id })
      else
        emit(run_record, 'tool.intended', { tool: intended_tool, executed: false, reason: not_acting_reason(tool) })
      end
    end

    # An `invoke_tool` decision only runs the tool — it carries no reply, so the conversation would
    # stall. Take a SECOND turn feeding the tool result back so the AI answers the customer with it.
    # Single hop (we don't execute another tool) to avoid loops; `result` is replaced for dispatch.
    if intended_tool.present? && @acts_live && execution&.status == 'executed'
      result = tool_followup(run_record, system_prompt, effective_content, intended_tool, execution)
    end

    # Intelligent handoff / close. Shadow records intention; live executes the native action.
    handoff = Ai::HandoffEvaluator.evaluate(
      decision: result[:decision] || {}, department: department, message_content: effective_content
    )
    decision_kind = (result[:decision] || {})['decision']
    if handoff[:handoff]
      # Try AI->AI routing first (to an allowed agent); otherwise hand to a human.
      routed = @acts_live && route_to_ai(result[:decision] || {}, run_record)
      unless routed
        # Tell the customer we're handing off (the model's "transferindo você..." text), THEN
        # transfer (reopen + unassign for a human). Without the reply the customer saw silence.
        handle_reply(department, (result[:decision] || {})['reply_text'], run_record)
        team_id = handoff_team_id(result[:decision] || {})
        input = { 'unassign' => true }
        input['team_id'] = team_id if team_id # roteia para o time; senão mantém o atual
        handle_action('conversation.transfer', input, run_record, 'handoff', extra: { reason: handoff[:reason], team_id: team_id })
      end
    elsif decision_kind == 'close'
      handle_action('conversation.resolve', {}, run_record, 'close')
    elsif decision_kind == 'reply'
      handle_reply(department, (result[:decision] || {})['reply_text'], run_record)
    elsif intended_tool.present? && @acts_live
      # Safety net: a tool ran but the follow-up decision still isn't a plain reply/close/handoff —
      # send whatever text we have so the customer is never left waiting after a tool call.
      handle_reply(department, (result[:decision] || {})['reply_text'], run_record)
    end

    update_memory(run_record)
    finalize(run_record, result[:status] == 'error' ? 'error' : 'recorded')
  rescue StandardError => e
    Rails.logger.error "[Ai::Gateway] conv=#{@conversation&.id} #{e.class}: #{e.message}"
    run_record.update!(status: 'error', error_type: 'unknown') if defined?(run_record) && run_record&.persisted?
    nil
  end

  private

  HISTORY_LIMIT = 12

  # The model used to receive ONLY the latest message, so it re-asked things already answered
  # (city/segment in a loop). Pair the current message with the recent transcript (everything up to
  # our last reply) so it has the conversation context. The current customer burst is kept separate
  # because grouping may join several messages into `current`.
  def build_user_message(current)
    last_out_id = @conversation.messages.outgoing.maximum(:id) || 0
    history = @conversation.messages
                           .where(message_type: %i[incoming outgoing])
                           .where('messages.id <= ?', last_out_id)
                           .order(created_at: :desc).limit(HISTORY_LIMIT).to_a.reverse
                           .map { |m| "#{m.incoming? ? 'Cliente' : 'Atendente'}: #{m.content.to_s.strip.first(500)}" }
                           .reject { |line| line.end_with?(': ') }
    return current if history.empty?

    "Histórico recente da conversa:\n#{history.join("\n")}\n\nMensagem atual do cliente:\n#{current}"
  end

  # Why an action was not executed: shadow binding, the department toggle off, or a missing tool.
  def not_acting_reason(tool = :present)
    return 'shadow_mode' unless @mode == 'live'
    return 'auto_attendance_off' unless @acts_live

    tool.nil? ? 'tool_not_found' : 'auto_attendance_off'
  end

  # Executes a native action in live mode (audited) or records intention otherwise.
  def handle_action(capability_key, input, run_record, label, extra: {})
    unless @acts_live
      emit(run_record, "#{label}.intended", extra.merge(executed: false, reason: not_acting_reason))
      return
    end

    output = Ai::CapabilityRegistry.execute(capability_key, conversation: @conversation, input: input)
    Ai::CapabilityExecution.create!(
      account_id: @account.id, conversation_id: @conversation.id, ai_run_id: run_record.id,
      capability_key: capability_key, input: input, output: output[:output], status: 'executed',
      governance: 'allowed', rollback_data: output[:rollback_data], requested_by: 'ai'
    )
    emit(run_record, "#{label}.executed", extra.merge(executed: true))
  rescue StandardError => e
    Rails.logger.error "[Ai::Gateway##{label}] #{e.class}: #{e.message}"
    emit(run_record, "#{label}.failed", { error: "#{e.class}: #{e.message}" })
  end

  # Sends the AI reply to the customer — the only outward-facing action. Gated by the department
  # reply_scope (off by default): 'all' replies to every live conversation, 'canary' only when the
  # conversation carries the configured label. Shadow / off / missing label records intention only.
  def handle_reply(department, text, run_record)
    return if text.blank?

    # Safety cap: stop replying after the department's max number of AI replies in this
    # conversation (0 = no limit). Counts 'reply.sent' events, so human agent replies don't count.
    max_replies = department.behavior.to_h['max_replies'].to_i
    if max_replies.positive? && ai_replies_count >= max_replies
      emit(run_record, 'reply.skipped', { reason: 'max_replies_reached', max: max_replies })
      return
    end

    state = Ai::ReplyPolicy.effective_reply_state(mode: @mode, department: department, conversation: @conversation)
    if state == :live
      Messages::MessageBuilder.new(nil, @conversation, { content: text, private: false }).perform
      emit(run_record, 'reply.sent', { chars: text.length })
    else
      reason = Ai::ReplyPolicy.skip_reason(mode: @mode, department: department, conversation: @conversation)
      emit(run_record, 'reply.intended', { executed: false, reason: reason })
    end
  rescue StandardError => e
    Rails.logger.error "[Ai::Gateway#reply] #{e.class}: #{e.message}"
    emit(run_record, 'reply.failed', { error: "#{e.class}: #{e.message}" })
  end

  # Second model turn after a tool ran: feeds the tool output back so the AI replies to the customer
  # with the result (e.g. coverage lookup -> "sim, atendemos sua cidade"). Returns the new decision
  # for the normal dispatch. Single hop — it never triggers another tool execution.
  def tool_followup(run_record, system_prompt, user_message, tool_call, execution)
    followup_message = "#{user_message}\n\n[Resultado da ferramenta \"#{tool_call['name']}\"]:\n" \
                       "#{execution.output.to_json}\n\n" \
                       'Use esse resultado para responder ao cliente agora (decision: "reply").'
    result = Ai::ModelRouter.decide(
      profile: @agent.operation_profile, system_prompt: system_prompt,
      user_message: followup_message, account_id: @account.id
    )
    emit(run_record, 'tool.followup',
         { decision: result[:decision], cost: result[:cost], latency_ms: result[:latency_ms] })
    result
  rescue StandardError => e
    Rails.logger.error "[Ai::Gateway#tool_followup] #{e.class}: #{e.message}"
    { decision: {} }
  end

  # Stores the conversation's current step + its grouping delay (from the playbook) so the next
  # message-grouping debounce can use the step-specific delay. Falls back to the general delay
  # when the step has no delay configured (handled in Ai::MessageGrouping).
  def track_step(department, decision)
    name = decision['current_step'].to_s.strip
    return if name.blank?

    steps = Array(department.playbook&.steps)
    step = steps.find { |s| s.is_a?(Hash) && (s['name'] || s[:name]).to_s.strip.casecmp?(name) }
    delay = (step && (step['group_delay_seconds'] || step[:group_delay_seconds])).to_i

    attrs = @conversation.additional_attributes || {}
    attrs['ai_step'] = { 'name' => name, 'grouping_delay_seconds' => (delay.positive? ? delay : nil) }
    @conversation.update!(additional_attributes: attrs)
  rescue StandardError => e
    Rails.logger.error "[Ai::Gateway#track_step] #{e.class}: #{e.message}"
  end

  MAX_AI_HOPS = 2

  # Routes the conversation to another AI agent the model chose (handoff_target), if it is in this
  # agent's allowlist and passes the anti-loop guard. Routing = set the conversation's team to the
  # target's team (that decides which AI is live) and re-enqueue the run. Returns true when routed.
  def route_to_ai(decision, run_record)
    target_name = decision['handoff_target'].to_s.strip
    return false if target_name.blank?

    allowed_ids = @agent.respond_to?(:handoff_agent_ids) ? Array(@agent.handoff_agent_ids) : []
    return false if allowed_ids.empty?

    target = ::Ai::Agent.where(account_id: @account.id, id: allowed_ids)
                        .find { |a| (a.assistant_name.presence || a.name).to_s.casecmp?(target_name) }
    return false if target.nil? || target.team_id.blank?

    chain = Array(@conversation.additional_attributes&.dig('ai_handoff_chain'))
    return false if chain.size >= MAX_AI_HOPS # anti-loop: cap on IA->IA hops
    return false if chain.include?(target.id)  # never revisit an agent in this chain

    @conversation.update!(team_id: target.team_id)
    attrs = @conversation.additional_attributes || {}
    attrs['ai_handoff_chain'] = chain + [target.id]
    @conversation.update!(additional_attributes: attrs)

    Ai::GatewayRunJob.perform_later(@message.id)
    emit(run_record, 'handoff.routed', { to_agent_id: target.id, to_team_id: target.team_id, hop: chain.size + 1 })
    true
  rescue StandardError => e
    Rails.logger.error "[Ai::Gateway#route_to_ai] #{e.class}: #{e.message}"
    false
  end

  # Human handoff routing: resolve the destination TEAM from the model's handoff_target (matched by
  # team name in this account). Returns nil when there's no match — then the transfer keeps the
  # conversation's current team and just unassigns (native auto-assignment picks a human).
  def handoff_team_id(decision)
    name = decision['handoff_target'].to_s.strip
    return nil if name.blank?

    ::Team.where(account_id: @account.id).find { |team| team.name.to_s.casecmp?(name) }&.id
  rescue StandardError => e
    Rails.logger.error "[Ai::Gateway#handoff_team_id] #{e.class}: #{e.message}"
    nil
  end

  # Number of AI replies already sent in this conversation (across runs/agents).
  def ai_replies_count
    Ai::Event.where(conversation_id: @conversation.id, event_type: 'reply.sent').count
  end

  # Invisible worker: persist a rolling conversation summary into agent memory.
  def update_memory(run_record)
    summary = Ai::Workers::Summary.generate(conversation: @conversation, agent: @agent)
    return if summary.blank?

    Ai::AgentMemory.find_or_initialize_by(conversation_id: @conversation.id, ai_agent_id: @agent.id)
                   .update!(summary: summary)
    emit(run_record, 'memory.updated', { chars: summary.length })
  rescue StandardError => e
    Rails.logger.error "[Ai::Gateway#memory] #{e.class}: #{e.message}"
  end

  def finalize(run_record, status)
    run_record.update!(status: status)
    run_record
  end

  def emit(run_record, type, payload, run_id: nil)
    Ai::Event.create!(
      account_id: @account.id, conversation_id: @conversation.id,
      ai_run_id: run_id, event_type: type, payload: payload, status: 'ok'
    )
  end
end
