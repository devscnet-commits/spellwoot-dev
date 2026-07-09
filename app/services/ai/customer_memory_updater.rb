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

    result = Ai::ModelRouter.decide(
      profile: nil, provider: 'openai', model: MODEL,
      system_prompt: build_prompt(memory), user_message: lines, account_id: @account.id, json: true
    )
    record_run(run, result)
    apply(memory, result[:decision] || {})
  end

  private

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

  def record_run(run, result)
    run.update!(
      provider: result[:provider], model: result[:model], tokens_in: result[:tokens_in],
      tokens_out: result[:tokens_out], cost: result[:cost], latency_ms: result[:latency_ms],
      decision: result[:decision] || {}, status: result[:status]
    )
  end
end
