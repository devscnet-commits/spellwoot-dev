# Powers the agent "Teste" tab: runs a one-off decision for a message and returns the breakdown
# (department, knowledge, suggested tool, model, tokens, cost, latency, reply). Pure dry-run.
class Ai::Tester
  def self.run(agent:, message:, department_id: nil)
    department = resolve_department(agent, message, department_id)
    return { 'error' => 'nenhum departamento ativo' } if department.nil?

    knowledge = Ai::KnowledgeRetriever.retrieve(department: department, query: message, account_id: agent.account_id)
    tools = department.tools.active.to_a
    system_prompt = Ai::PromptCompiler.compile(
      agent: agent, department: department, knowledge: knowledge, memory: nil, tools: tools
    )
    result = Ai::ModelRouter.decide(profile: agent.operation_profile, system_prompt: system_prompt, user_message: message)
    decision = result[:decision] || {}

    {
      'department' => department.name,
      'reply' => decision['reply_text'],
      'tool' => decision.dig('tool', 'name'),
      'knowledge_used' => knowledge.size,
      'knowledge_preview' => knowledge.first(3).map { |k| k.to_s.first(160) },
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

  def self.resolve_department(agent, message, department_id)
    return agent.departments.find_by(id: department_id) if department_id.present?

    Ai::DepartmentResolver.resolve(agent: agent, inbox_id: nil, message_content: message).first
  end
end
