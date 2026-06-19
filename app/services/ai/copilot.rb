# Agent-facing copilot: given a conversation, suggests a reply, a summary and next steps.
# SUGGESTION ONLY — it never sends anything to the customer and never executes tools. Safe in any
# mode; it's triggered on demand by a human agent. Records an ai_run (run_type=copilot) for audit.
class Ai::Copilot
  TRANSCRIPT_LIMIT = 12

  def initialize(conversation:, requested_by: nil)
    @conversation = conversation
    @account = conversation.account
    @requested_by = requested_by
  end

  def suggest
    binding = resolve_binding
    return { 'error' => 'nenhum agente IA vinculado a esta caixa' } if binding.nil?

    agent = binding.agent
    department, = Ai::DepartmentResolver.resolve(
      agent: agent, inbox_id: @conversation.inbox_id, message_content: last_customer_message
    )
    return { 'error' => 'nenhum departamento ativo' } if department.nil?

    knowledge = Ai::KnowledgeRetriever.retrieve(
      department: department, query: last_customer_message, account_id: @account.id
    )

    run = Ai::Run.create!(
      account_id: @account.id, conversation_id: @conversation.id, ai_agent_id: agent.id,
      run_type: 'copilot', mode: 'copilot', status: 'running'
    )
    result = Ai::ModelRouter.decide(
      profile: agent.operation_profile,
      system_prompt: build_prompt(agent, department, knowledge),
      user_message: transcript
    )
    run.update!(
      provider: result[:provider], model: result[:model], tokens_in: result[:tokens_in],
      tokens_out: result[:tokens_out], cost: result[:cost], latency_ms: result[:latency_ms],
      decision: result[:decision] || {}, status: result[:status]
    )

    suggestions = result[:decision] || {}
    Ai::Event.create!(
      account_id: @account.id, conversation_id: @conversation.id, ai_run_id: run.id,
      event_type: 'copilot.suggested', payload: suggestions
    )
    suggestions.merge('run_id' => run.id, 'status' => result[:status])
  rescue StandardError => e
    Rails.logger.error "[Ai::Copilot] conv=#{@conversation&.id} #{e.class}: #{e.message}"
    { 'error' => "#{e.class}: #{e.message}" }
  end

  private

  def resolve_binding
    bindings = Ai::AgentInbox.where(inbox_id: @conversation.inbox_id, active: true).includes(:agent).to_a
    bindings.find { |b| b.mode == 'live' } || bindings.first
  end

  def last_customer_message
    @conversation.messages.where(message_type: :incoming).order(created_at: :desc).limit(1).pick(:content).to_s
  end

  def transcript
    @conversation.messages
                 .where(message_type: %i[incoming outgoing])
                 .order(created_at: :desc).limit(TRANSCRIPT_LIMIT).to_a.reverse
                 .map { |m| "#{m.incoming? ? 'Cliente' : 'Atendente'}: #{m.content}" }
                 .join("\n")
  end

  def build_prompt(agent, department, knowledge)
    parts = []
    parts << 'Você é um COPILOTO que ajuda o ATENDENTE HUMANO. Você NUNCA responde o cliente diretamente.'
    parts << "Assistente da empresa: #{agent.assistant_name.presence || agent.name}. #{agent.base_prompt}"
    parts << "Departamento: #{department.name}. Objetivo: #{department.objetivo}."
    if (pb = department.playbook) && pb.steps.present?
      parts << "Etapas do atendimento: #{Array(pb.steps).join(' -> ')}."
    end
    parts << "Base de conhecimento relevante:\n#{knowledge.join("\n---\n")}" if knowledge.present?
    parts << 'Com base na conversa, retorne ESTRITAMENTE um JSON: ' \
             '{"suggested_reply":"sugestão de resposta ao cliente","summary":"resumo da conversa","next_steps":["passo 1","passo 2"]}'
    parts.join("\n\n")
  end
end
