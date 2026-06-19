# The AI Gateway — F1 happy-path, SHADOW only.
# Pipeline: message.received -> resolve_agent (caller) -> resolve_department -> assemble_context
#           -> retrieve_knowledge -> decide -> record ai_runs + ai_events.
# In shadow it NEVER replies, NEVER executes a tool, NEVER writes operational changes — it only
# records intention, runs and events.
class Ai::Gateway
  def initialize(message:, agent_inbox:)
    @message = message
    @agent_inbox = agent_inbox
    @agent = agent_inbox.agent
    @conversation = message.conversation
    @account = message.account
    @mode = agent_inbox.mode
  end

  def run
    run_record = Ai::Run.create!(
      account_id: @account.id, conversation_id: @conversation.id, ai_agent_id: @agent.id,
      run_type: 'decision', mode: @mode, status: 'running'
    )
    emit(run_record, 'message.received', { content: @message.content.to_s.first(500) })

    department = resolve_department
    emit(run_record, 'department.resolved', { department_id: department&.id, name: department&.name })
    return finalize(run_record, 'no_department') unless department

    knowledge = Ai::KnowledgeRetriever.retrieve(department: department, query: @message.content, account_id: @account.id)
    emit(run_record, 'knowledge.retrieved', { count: knowledge.size, preview: knowledge.first(2) })

    memory = Ai::AgentMemory.find_by(conversation_id: @conversation.id, ai_agent_id: @agent.id)
    tools  = department.tools.active.to_a
    system_prompt = Ai::PromptCompiler.compile(
      agent: @agent, department: department, knowledge: knowledge, memory: memory, tools: tools
    )
    emit(run_record, 'context.assembled', { prompt_chars: system_prompt.length, tools: tools.map(&:name) })

    result = Ai::ModelRouter.decide(
      profile: @agent.operation_profile, system_prompt: system_prompt, user_message: @message.content.to_s
    )
    run_record.update!(
      provider: result[:provider], model: result[:model],
      tokens_in: result[:tokens_in], tokens_out: result[:tokens_out],
      cost: result[:cost], latency_ms: result[:latency_ms],
      decision: result[:decision] || {}, status: result[:status]
    )
    emit(run_record, 'decision.made',
         { decision: result[:decision], cost: result[:cost], latency_ms: result[:latency_ms] },
         run_id: run_record.id)

    # Tool handling. SHADOW never executes — only records intention. LIVE runs the executor,
    # which itself enforces governance (allowed runs now; confirmation/approval stays pending).
    intended_tool = result.dig(:decision, 'tool')
    if intended_tool.present?
      tool = department.tools.active.find_by(name: intended_tool['name'])
      if @mode == 'live' && tool
        execution = Ai::ToolExecutor.new(
          tool: tool, input: intended_tool['input'], conversation: @conversation, mode: @mode, run: run_record
        ).perform
        emit(run_record, 'tool.executed',
             { tool: tool.name, status: execution.status, governance: tool.governance, execution_id: execution.id })
      else
        emit(run_record, 'tool.intended',
             { tool: intended_tool, executed: false, reason: @mode == 'live' ? 'tool_not_found' : 'shadow_mode' })
      end
    end

    finalize(run_record, result[:status] == 'error' ? 'error' : 'recorded')
  rescue StandardError => e
    Rails.logger.error "[Ai::Gateway] conv=#{@conversation&.id} #{e.class}: #{e.message}"
    nil
  end

  private

  # Single-department slice: the agent's active department (Comercial). A future version resolves
  # by inbox->department and an optional classifier worker.
  def resolve_department
    @agent.departments.active.first
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
