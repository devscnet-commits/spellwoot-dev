# Updates a contact's persistent memory from one resolved conversation. Opção A: always the cheap
# model (gpt-4.1-mini) on the account's own OpenAI key, one LLM call per resolved conversation.
# Incremental merge: the model receives the CURRENT memory + the transcript and returns the merged
# {summary, key_facts}; key_facts are additionally merged on our side so a fact the model forgot to
# echo is never silently lost. Records an Ai::Run for cost/audit, like Ai::ShadowEvaluator.
class Ai::CustomerMemoryUpdater
  MODEL = 'gpt-4.1-mini'
  TRANSCRIPT_LIMIT = 30

  def initialize(conversation:)
    @conversation = conversation
    @account = conversation.account
    @contact = conversation.contact
  end

  def update
    lines = transcript
    return if lines.blank? # nothing was said — don't spend a call or overwrite good memory

    memory = Ai::CustomerMemory.find_or_initialize_by(contact_id: @contact.id, account_id: @account.id)
    run = create_run
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # call_model (texto LIVRE, SEM schema) — como o handoff_summary/PromptAssistant. O `decide` anexa o
    # DecisionSchema strict e a saída vira o ENVELOPE de decisão (decision/asked_slot/confidence/reply_text),
    # NUNCA o {"summary","key_facts"} que o prompt pede. Mesmo bug do #302: quebrou em 3cc275025, quando o
    # decide virou strict — o updater é anterior e funcionava com o decide frouxo. Sem cobertura, passou batido.
    raw = Ai::ModelRouter.call_model(
      provider: 'openai', model: MODEL,
      system_prompt: build_prompt(memory), user_message: lines, account_id: @account.id, json: true
    )
    parsed = parse_memory(raw[:text])
    record_run(run, raw, parsed, started)
    apply(memory, parsed)
  end

  private

  # call_model devolve TEXTO CRU (sem schema): extraímos o {"summary","key_facts"} nós mesmos (parser
  # tolerante, como o handoff_summary/PromptAssistant#extract_suggestion). {} quando não vier JSON — o
  # apply então PRESERVA a memória atual (summary não vira nil, key_facts não perde nada).
  def parse_memory(text)
    json = text.to_s[/\{.*\}/m]
    return {} if json.blank?

    JSON.parse(json)
  rescue JSON::ParserError
    {}
  end

  # Merge the model's output into the stored memory. Summary is replaced (the model already merged
  # the old one in); key_facts are merged key-by-key so we only add/update, never drop known facts.
  def apply(memory, decision)
    new_facts = decision['key_facts']
    new_facts = {} unless new_facts.is_a?(Hash)
    memory.summary = decision['summary'].presence || memory.summary
    memory.key_facts = memory.key_facts.to_h.merge(new_facts)
    memory.conversations_count = memory.conversations_count.to_i + 1
    memory.last_updated_at = Time.current
    memory.save!
    memory
  end

  def build_prompt(memory)
    parts = []
    parts << 'Você mantém a MEMÓRIA PERSISTENTE de um cliente entre conversas. A partir da conversa ' \
             'abaixo, ATUALIZE a memória: preserve o que continua verdadeiro, corrija o que mudou e ' \
             'acrescente o que for novo. Não invente — registre apenas o que o cliente disse ou o que ficou claro.'
    parts << current_memory_block(memory)
    parts << 'Retorne ESTRITAMENTE um JSON válido, sem texto fora dele: ' \
             '{"summary":"resumo curto do cliente em 1-3 frases","key_facts":{"chave":"valor"}}. ' \
             'Em key_facts use chaves estáveis e curtas (ex.: cidade, plano, preferencia_contato). ' \
             'Se nada relevante houver, devolva summary vazio e key_facts {}.'
    parts.join("\n\n")
  end

  def current_memory_block(memory)
    return 'Memória atual: (vazia — este é o primeiro registro deste cliente).' unless memory.persisted?

    facts = memory.key_facts.to_h.map { |k, v| "- #{k}: #{v}" }.join("\n")
    [
      'Memória atual deste cliente (base para a atualização):',
      ("Resumo: #{memory.summary}" if memory.summary.present?),
      (facts.present? ? "Fatos:\n#{facts}" : nil)
    ].compact.join("\n")
  end

  def transcript
    @conversation.messages
                 .where(message_type: %i[incoming outgoing])
                 .order(created_at: :desc).limit(TRANSCRIPT_LIMIT).to_a.reverse
                 .map { |m| "#{m.incoming? ? 'Cliente' : 'Atendente'}: #{m.content}" }
                 .reject { |line| line.end_with?(': ') }
                 .join("\n")
  end

  def create_run
    Ai::Run.create!(
      account_id: @account.id, conversation_id: @conversation.id, inbox_id: @conversation.inbox_id,
      run_type: 'customer_memory', mode: 'shadow', status: 'running'
    )
  end

  # call_model NÃO devolve cost/latency/decision (o decide devolvia) — computamos aqui, como o
  # PromptAssistant, senão o ai:cost_report subconta a memória. `decision` guarda o {summary,key_facts} parseado.
  def record_run(run, raw, parsed, started)
    tin = raw[:tokens_in].to_i
    tout = raw[:tokens_out].to_i
    run.update!(
      provider: raw[:provider] || 'openai', model: raw[:model] || MODEL, tokens_in: tin, tokens_out: tout,
      cost: Ai::ModelRouter.estimate_cost(MODEL, tin, tout),
      latency_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round,
      decision: parsed, status: raw[:status]
    )
  end
end
