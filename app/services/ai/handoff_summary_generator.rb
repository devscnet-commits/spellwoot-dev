# Gera o resumo dedicado da conversa quando a IA transfere AUTOMATICAMENTE para um humano (loop,
# crédito esgotado, handoff nativo por baixa confiança). Resumo NOVO do momento do handoff — NÃO
# reaproveita o ai_agent_memory.summary rolling (esse entra só como contexto de apoio).
#
# Registra um Ai::Run (run_type=handoff_summary, mode=assistant) para rastreio de custo nos relatórios,
# mas NÃO consome crédito da conta (mesmo padrão real do Copilot/PromptAssistant). Best-effort: qualquer
# erro é logado e devolve nil — nunca quebra o handoff (que já aconteceu antes; isto roda em job).
class Ai::HandoffSummaryGenerator
  # Mais mensagens que o gateway normal (12): o resumo precisa de contexto amplo da conversa toda.
  TRANSCRIPT_LIMIT = 40

  # Rótulos legíveis do motivo, para o atendente entender POR QUE caiu para humano.
  REASON_LABELS = {
    'loop' => 'a IA entrou em repetição/loop e não conseguiu avançar',
    'credit_exhausted' => 'os créditos de IA da conta se esgotaram',
    'modelo_pediu_transferencia' => 'a própria IA decidiu transferir (baixa confiança ou pedido explícito)',
    'palavra_chave' => 'o cliente usou uma palavra-chave que aciona atendimento humano'
  }.freeze

  def initialize(conversation:, reason:)
    @conversation = conversation
    @account = conversation.account
    @reason = reason.to_s
  end

  def generate
    agent = resolve_agent
    run = Ai::Run.create!(
      account_id: @account.id, conversation_id: @conversation.id, ai_agent_id: agent&.id,
      run_type: 'handoff_summary', mode: 'assistant', status: 'running'
    )
    result = Ai::ModelRouter.decide(
      profile: agent&.operation_profile, system_prompt: build_prompt(agent),
      user_message: transcript, account_id: @account.id, json: true
    )
    run.update!(
      provider: result[:provider], model: result[:model], tokens_in: result[:tokens_in],
      tokens_out: result[:tokens_out], cost: result[:cost], latency_ms: result[:latency_ms],
      decision: result[:decision] || {}, status: result[:status]
    )

    content = extract_summary(result[:decision])
    return nil if content.blank?

    Ai::HandoffSummary.create!(
      account_id: @account.id, conversation_id: @conversation.id, ai_run_id: run.id,
      reason: @reason, content: content
    )
  rescue StandardError => e
    Rails.logger.error "[Ai::HandoffSummaryGenerator] conv=#{@conversation&.id} #{e.class}: #{e.message}"
    nil
  end

  private

  # Agente vinculado à caixa (prefere o live) — usado para o profile (provider) e a memória do agente.
  def resolve_agent
    bindings = Ai::AgentInbox.where(inbox_id: @conversation.inbox_id, active: true).includes(:agent).to_a
    (bindings.find { |b| b.mode == 'live' } || bindings.first)&.agent
  end

  def extract_summary(decision)
    decision.is_a?(Hash) ? decision['summary'].to_s.strip : ''
  end

  def transcript
    @conversation.messages
                 .where(message_type: %i[incoming outgoing])
                 .order(created_at: :desc).limit(TRANSCRIPT_LIMIT).to_a.reverse
                 .map { |m| "#{m.incoming? ? 'Cliente' : 'Atendente'}: #{m.content.to_s.strip}" }
                 .reject { |line| line.end_with?(': ') }
                 .join("\n")
  end

  def build_prompt(agent)
    parts = []
    parts << 'Você resume uma conversa de atendimento para o ATENDENTE HUMANO que vai assumir agora. ' \
             'Seja objetivo — o atendente precisa entrar na conversa rapidamente e sem reler tudo.'
    parts << "Motivo da transferência para humano: #{reason_label}."
    if (attrs = collected_attributes).present?
      parts << "Dados já coletados do cliente: #{attrs}."
    end
    if (mem = agent_memory_summary(agent)).present?
      parts << "Contexto acumulado (memória do agente, apenas apoio — NÃO copie): #{mem}"
    end
    parts << 'Com base no histórico da conversa abaixo, retorne ESTRITAMENTE um JSON no formato ' \
             '{"summary":"..."}. O resumo deve ser em português, no máximo 4 frases, cobrindo: o que o ' \
             'cliente quer, o estado atual do atendimento e o que ficou pendente para o atendente resolver.'
    parts.join("\n\n")
  end

  def reason_label
    REASON_LABELS[@reason] || @reason
  end

  def collected_attributes
    (@conversation.contact&.custom_attributes || {})
      .merge(@conversation.custom_attributes || {})
      .reject { |_, v| v.blank? }
      .map { |k, v| "#{k}: #{v}" }.join(', ')
  end

  def agent_memory_summary(agent)
    return nil unless agent

    Ai::AgentMemory.find_by(conversation_id: @conversation.id, ai_agent_id: agent.id)&.summary.presence
  end
end
