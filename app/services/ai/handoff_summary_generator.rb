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
    'palavra_chave' => 'o cliente usou uma palavra-chave que aciona atendimento humano',
    # Redes de "travou" (Ai::StepResolver): o atendente lia o token cru ("Transferido por: max_turns").
    'max_turns' => 'a conversa passou muitas mensagens sem avançar',
    'max_questions' => 'o cliente fez muitas perguntas seguidas sem fechar o atendimento',
    'declined' => 'o cliente preferiu não informar um dado necessário para continuar',
    # (b)-core: desfecho declarado pela etapa (step['on_complete']) — o funil chegou ao fim.
    'conclusao' => 'o atendimento da IA foi concluído e encaminhado para seguimento humano',
    # Fase 1 erro de provedor: rate-limit/cota/billing (ou auth não recuperado). Rótulo do card (o atendente
    # vê); o cliente nunca lê o motivo técnico.
    'provider_unavailable' => 'o provedor de IA ficou indisponível (verifique cota/billing) e o atendimento foi encaminhado para um humano'
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
    # BUG DA 394: usava ModelRouter.decide, que força o SCHEMA DE DECISÃO strict (reply/handoff/close/tool,
    # SEM campo summary) -> o modelo devolvia uma DECISÃO (handoff), nunca um resumo, e o summary era
    # IMPOSSÍVEL na saída. Agora usa call_model (entrada LIVRE, sem schema), como o CaptureJudge -> o
    # {"summary"} do prompt volta a valer. call_model NÃO devolve cost/latency (o decide devolvia), então
    # computamos aqui (senão o ai:cost_report subconta o resumo).
    provider, model = summary_model(agent)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    raw = Ai::ModelRouter.call_model(
      provider: provider, model: model, system_prompt: build_prompt(agent),
      user_message: transcript, account_id: @account.id, json: true
    )
    tin = raw[:tokens_in].to_i
    tout = raw[:tokens_out].to_i
    llm_summary = extract_summary(raw[:text])
    run.update!(
      provider: provider, model: model, tokens_in: tin, tokens_out: tout,
      cost: Ai::ModelRouter.estimate_cost(model, tin, tout),
      latency_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round,
      decision: { 'summary' => llm_summary }, status: raw[:status] == 'error' ? 'error' : 'recorded'
    )

    # NUNCA vazio (rede de segurança): LLM em branco/JSON inválido/status error -> resumo determinístico.
    # O resumo do LLM VENCE quando existe (conv 394: quem assume no meio é quem MAIS precisa de contexto).
    content = llm_summary.presence || deterministic_fallback

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

  # provider/model do perfil do agente (supervisor + defaults) — mesmo padrão do CaptureJudge.worker_config.
  # Não há worker override próprio p/ o resumo; usa o supervisor do perfil.
  def summary_model(agent)
    profile = agent&.operation_profile
    [profile&.supervisor_provider.presence || 'openai',
     profile&.supervisor_model.presence || 'gpt-4.1-mini']
  end

  # Parser tolerante próprio (NÃO schema strict): extrai {"summary":...} do texto CRU do call_model, como
  # CaptureJudge.parse. Vazio quando não há JSON / não há summary / JSON inválido -> o caller cai no fallback.
  def extract_summary(text)
    json = text.to_s[/\{.*\}/m]
    return '' if json.blank?

    JSON.parse(json)['summary'].to_s.strip
  rescue JSON::ParserError
    ''
  end

  # Resumo DETERMINÍSTICO (rede de segurança) — quando o LLM não produz summary. Monta a partir do que já
  # existe: os fatos coletados (collected_attributes) + o motivo (reason_label). Vale p/ os 4 motivos (este
  # generator é compartilhado por normal/loop/stuck/credit via assign_human). NUNCA vazio: o piso é só o
  # motivo. NOTA: se cair no piso (sem fatos) numa conversa já avançada, o problema é a COLETA (fatos fora
  # do ai_collected_facts), não o resumo — investigar à parte. O nome da etapa NÃO entra aqui: é frágil de
  # resolver (o ai_step_index é relativo ao department, que não é persistido) e já vem no reason do stuck.
  def deterministic_fallback
    facts = collected_attributes
    coletado = facts.present? ? "Coletado até aqui: #{facts}." : 'Nenhum dado coletado ainda.'
    "#{coletado} Transferido por: #{reason_label}."
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

  # Três fontes, do menos para o mais confiável: ai_collected_facts (o que a IA capturou no turno,
  # inclusive chaves sem CustomAttributeDefinition espelhada) como base, depois os custom_attributes
  # do contato e da conversa por cima — se a mesma chave existir, vence o custom_attribute, que pode
  # ter sido corrigido por um humano no painel.
  def collected_attributes
    # Gap 1: o token de ausência (só existe em ai_collected_facts) é mapeado p/ "não informado" — o
    # resumo do handoff é lido por um humano e NUNCA deve mostrar o token cru.
    attributes_by_precedence
      .reject { |_, v| v.blank? }
      .map { |k, v| "#{k}: #{Ai::StepSlot.display(v)}" }.join(', ')
  end

  def attributes_by_precedence
    facts = (@conversation.additional_attributes || {})['ai_collected_facts'] || {}
    facts.merge(@conversation.contact&.custom_attributes || {})
         .merge(@conversation.custom_attributes || {})
  end

  def agent_memory_summary(agent)
    return nil unless agent

    Ai::AgentMemory.find_by(conversation_id: @conversation.id, ai_agent_id: agent.id)&.summary.presence
  end
end
