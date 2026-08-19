# Powers the agent "Teste" tab: runs a one-off decision for a message and returns the breakdown
# (knowledge, suggested tool, model, tokens, cost, latency, reply). Pure dry-run.
class Ai::Tester
  def self.run(agent:, message:)
    retrieval = Ai::KnowledgeRetriever.retrieve_scored(query: message, account_id: agent.account_id)
    knowledge = retrieval[:chunks]
    score = retrieval[:top_score]
    # Pedido do usuário (18/08): a tela de Perfis de Operação parou de ter QUALQUER UI para
    # cheap_provider/cheap_model/premium_provider/premium_model (nunca teve, na prática — ver
    # docs/ai-operation-profiles-screen-assessment.md §2), então Ai::RoutingStrategy.decide sempre
    # caía no MESMO modelo do perfil pros dois tiers — não fazia roteamento real nenhum, só rotulava
    # a faixa de confiança. Comentado (não apagado) a pedido: preservado pra quando o roteamento por
    # confiança for refeito de verdade pro motor Python, em vez de reimplementar do zero.
    # routing = Ai::RoutingStrategy.decide(score: score, profile: agent.operation_profile)

    tools = agent.tools.active.to_a
    system_prompt = Ai::PromptCompiler.compile(
      agent: agent, department: agent, knowledge: knowledge, memory: nil, tools: tools
    )
    result = execute_routing(agent, system_prompt, message)
    decision = result[:decision] || {}

    {
      'reply' => decision['reply_text'],
      'decision' => decision['decision'],
      'confidence' => decision['confidence'],
      'handoff_reason' => decision['handoff_reason'],
      'tool' => decision.dig('tool', 'name'),
      'tools_considered' => tools.map(&:name),
      'knowledge_used' => knowledge.size,
      'knowledge_preview' => knowledge.first(3).map { |k| k.to_s.first(160) },
      'vector_score' => score,
      # 'routing_band' => routing['band'],
      # 'routing_action' => routing['action'],
      # 'worker' => routing['worker'],
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

  # Roda direto no provider/modelo do próprio perfil (sem tiering por confiança — ver comentário em
  # #run sobre Ai::RoutingStrategy comentado). Mantido como método próprio (não inline em #run) pra
  # facilitar reativar o roteamento por confiança depois, se/quando decidirem refazer isso pro Python.
  def self.execute_routing(agent, system_prompt, message)
    Ai::ModelRouter.decide(profile: agent.operation_profile, system_prompt: system_prompt,
                           user_message: message, account_id: agent.account_id)
  end
end
