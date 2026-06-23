# The AI Gateway — F1 happy-path, SHADOW only.
# Pipeline: message.received -> resolve_agent (caller) -> resolve_department -> assemble_context
#           -> retrieve_knowledge -> decide -> record ai_runs + ai_events.
# In shadow it NEVER replies, NEVER executes a tool, NEVER writes operational changes — it only
# records intention, runs and events.
class Ai::Gateway
  def initialize(message:, agent_inbox:, mode: nil)
    @message = message
    @agent_inbox = agent_inbox
    @agent = agent_inbox.agent
    @conversation = message.conversation
    @account = message.account
    # mode may be downgraded by the caller (team routing): a non-owner agent observes (shadow).
    @mode = mode || agent_inbox.mode
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
    effective_content = [@message.content, media_text].compact.join("\n").strip

    department, resolution = Ai::DepartmentResolver.resolve(
      agent: @agent, inbox_id: @message.inbox_id, message_content: effective_content
    )
    emit(run_record, 'department.resolved', { department_id: department&.id, name: department&.name, method: resolution })
    return finalize(run_record, 'no_department') unless department

    run_record.update!(ai_department_id: department.id)

    # Single gate for every outward action (reply, tools, transfer/resolve): the AI only acts when
    # this conversation is effectively live — i.e. live binding + auto_attendance on + within hours
    # + reply_scope all/canary-match. Otherwise it observes (records intention) only, so a live
    # binding piloted "behind canary" never touches non-canary conversations.
    @acts_live =
      Ai::ReplyPolicy.effective_reply_state(mode: @mode, department: department, conversation: @conversation) == :live

    knowledge = Ai::KnowledgeRetriever.retrieve(department: department, query: effective_content, account_id: @account.id)
    emit(run_record, 'knowledge.retrieved', { count: knowledge.size, preview: knowledge.first(2) })
    run_record.update!(knowledge_count: knowledge.size)

    memory = Ai::AgentMemory.find_by(conversation_id: @conversation.id, ai_agent_id: @agent.id)
    tools  = department.tools.active.to_a
    system_prompt = Ai::PromptCompiler.compile(
      agent: @agent, department: department, knowledge: knowledge, memory: memory, tools: tools
    )
    emit(run_record, 'context.assembled', { prompt_chars: system_prompt.length, tools: tools.map(&:name) })

    result = Ai::ModelRouter.decide(
      profile: @agent.operation_profile, system_prompt: system_prompt, user_message: effective_content
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

    # Tool handling. SHADOW never executes — only records intention. LIVE runs the executor,
    # which itself enforces governance (allowed runs now; confirmation/approval stays pending).
    intended_tool = result.dig(:decision, 'tool')
    if intended_tool.present?
      tool = department.tools.active.find_by(name: intended_tool['name'])
      if @acts_live && tool
        execution = Ai::ToolExecutor.new(
          tool: tool, input: intended_tool['input'], conversation: @conversation, mode: @mode, run: run_record
        ).perform
        emit(run_record, 'tool.executed',
             { tool: tool.name, status: execution.status, governance: tool.governance, execution_id: execution.id })
      else
        emit(run_record, 'tool.intended', { tool: intended_tool, executed: false, reason: not_acting_reason(tool) })
      end
    end

    # Intelligent handoff / close. Shadow records intention; live executes the native action.
    handoff = Ai::HandoffEvaluator.evaluate(
      decision: result[:decision] || {}, department: department, message_content: effective_content
    )
    decision_kind = (result[:decision] || {})['decision']
    if handoff[:handoff]
      handle_action('conversation.transfer', { 'unassign' => true }, run_record, 'handoff', extra: { reason: handoff[:reason] })
    elsif decision_kind == 'close'
      handle_action('conversation.resolve', {}, run_record, 'close')
    elsif decision_kind == 'reply'
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
