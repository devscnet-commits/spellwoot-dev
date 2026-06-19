# Powers the agent "Teste" tab: runs a one-off decision for a message and returns the breakdown
# (department, knowledge, suggested tool, model, tokens, cost, latency, reply). Pure dry-run.
class Ai::Tester
  def self.run(agent:, message:, department_id: nil)
    department = resolve_department(agent, message, department_id)
    return { 'error' => 'nenhum departamento ativo' } if department.nil?

    retrieval = Ai::KnowledgeRetriever.retrieve_scored(department: department, query: message, account_id: agent.account_id)
    knowledge = retrieval[:chunks]
    score = retrieval[:top_score]
    routing = Ai::RoutingStrategy.decide(score: score, profile: agent.operation_profile)

    tools = department.tools.active.to_a
    system_prompt = Ai::PromptCompiler.compile(
      agent: agent, department: department, knowledge: knowledge, memory: nil, tools: tools
    )
    result = execute_routing(routing, agent, system_prompt, message, knowledge)
    decision = result[:decision] || {}

    {
      'department' => department.name,
      'reply' => decision['reply_text'],
      'tool' => decision.dig('tool', 'name'),
      'knowledge_used' => knowledge.size,
      'knowledge_preview' => knowledge.first(3).map { |k| k.to_s.first(160) },
      'vector_score' => score,
      'routing_band' => routing['band'],
      'routing_action' => routing['action'],
      'worker' => routing['worker'],
      'provider' => result[:provider],
      'model' => result[:model],
      'tokens_in' => result[:tokens_in],
      'tokens_out' => result[:tokens_out],
      'latency_ms' => result[:latency_ms],
      'cost' => result[:cost],
      'status' => result[:status],
      'error' => decision['error']
    }
  rescue StandardError => e
    Rails.logger.error "[Ai::Tester] #{e.class}: #{e.message}"
    { 'error' => "#{e.class}: #{e.message}" }
  end

  # High-confidence band serves the best knowledge chunk with no LLM (instant, free); otherwise
  # the chosen tier (cheap/premium) model generates. Mirrors the approved confidence routing.
  def self.execute_routing(routing, agent, system_prompt, message, knowledge)
    if routing['action'] == 'cache' && knowledge.any?
      return { provider: 'cache', model: 'cache', tokens_in: 0, tokens_out: 0, cost: 0.0,
               latency_ms: 0, status: 'success', decision: { 'reply_text' => knowledge.first } }
    end

    Ai::ModelRouter.decide(profile: agent.operation_profile, system_prompt: system_prompt,
                           user_message: message, provider: routing['provider'], model: routing['model'])
  end

  def self.resolve_department(agent, message, department_id)
    return agent.departments.find_by(id: department_id) if department_id.present?

    Ai::DepartmentResolver.resolve(agent: agent, inbox_id: nil, message_content: message).first
  end
end
