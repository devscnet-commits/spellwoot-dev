# Extraído do Ai::Gateway (quebra do God object — Passo 4): escreve o ESTADO DERIVADO da decisão na
# conversa/agente — atributos coletados, etapa atual (p/ o agrupamento) e o resumo rolante na memória.
# São gravações idempotentes com rescue próprio (nunca derrubam o run). Contexto injetado no initialize;
# `run_record` NÃO é necessário (só ia pro emit, que ignorava) — some das assinaturas. Emite os MESMOS
# ai_events de antes (attributes.updated / memory.updated) via emit próprio.
class Ai::StateManager
  def initialize(conversation:, agent:)
    @conversation = conversation
    @agent = agent
  end

  # Persiste nos atributos da conversa os dados que o modelo coletou (campo `attributes` da decisão).
  # Merge, ignora vazios e no-ops. Na próxima volta o PromptCompiler injeta como "Dados já coletados".
  def persist_attributes(attrs)
    return unless attrs.is_a?(Hash)

    cleaned = attrs.reject { |_k, v| v.to_s.strip.empty? }
    return if cleaned.empty?

    merged = (@conversation.custom_attributes || {}).merge(cleaned)
    return if merged == @conversation.custom_attributes

    @conversation.update!(custom_attributes: merged)
    emit('attributes.updated', { keys: cleaned.keys })
  rescue StandardError => e
    Rails.logger.error "[Ai::StateManager#persist_attributes] #{e.class}: #{e.message}"
  end

  # Stores the conversation's current step + its grouping delay (from the playbook) so the next
  # message-grouping debounce can use the step-specific delay. Falls back to the general delay
  # when the step has no delay configured (handled in Ai::MessageGrouping).
  def track_step(department, decision, dispatcher: nil, run: nil)
    name = decision['current_step'].to_s.strip
    return if name.blank?

    steps = Array(department.playbook&.steps)
    step = steps.find { |s| s.is_a?(Hash) && (s['name'] || s[:name]).to_s.strip.casecmp?(name) }
    delay = (step && (step['group_delay_seconds'] || step[:group_delay_seconds])).to_i

    attrs = @conversation.additional_attributes || {}
    attrs['ai_step'] = { 'name' => name, 'grouping_delay_seconds' => (delay.positive? ? delay : nil) }
    @conversation.update!(additional_attributes: attrs)

    run_step_automations(department, decision, step, name, dispatcher, run)
  rescue StandardError => e
    Rails.logger.error "[Ai::StateManager#track_step] #{e.class}: #{e.message}"
  end

  # Invisible worker: persist a rolling conversation summary into agent memory.
  def update_memory
    summary = Ai::Workers::Summary.generate(conversation: @conversation, agent: @agent)
    return if summary.blank?

    Ai::AgentMemory.find_or_initialize_by(conversation_id: @conversation.id, ai_agent_id: @agent.id)
                   .update!(summary: summary)
    emit('memory.updated', { chars: summary.length })
  rescue StandardError => e
    Rails.logger.error "[Ai::StateManager#memory] #{e.class}: #{e.message}"
  end

  private

  # Dispara as automações da etapa CONCLUÍDA. Só quando o modelo sinaliza step_completed E ainda não
  # disparamos para essa etapa nesta conversa (idempotência via ai_completed_steps) — nunca em toda
  # leitura de current_step. Marca como concluída ANTES de rodar (não reprocessa se algo demorar/falhar).
  # Precisa do dispatcher + run (do Gateway) para as ações auditadas; sem eles, não roda.
  def run_step_automations(department, decision, step, name, dispatcher, run)
    return unless dispatcher && run
    return unless truthy?(decision['step_completed'])

    completed = Array(@conversation.additional_attributes&.dig('ai_completed_steps'))
    return if completed.include?(name)

    attrs = @conversation.additional_attributes || {}
    attrs['ai_completed_steps'] = completed + [name]
    @conversation.update!(additional_attributes: attrs)

    automations = Array(step && (step['automations'] || step[:automations]))
    return if automations.blank?

    Ai::StepAutomationRunner.new(
      conversation: @conversation, account: @conversation.account, agent: @agent,
      dispatcher: dispatcher, run: run
    ).run(step)
  end

  def truthy?(value)
    value == true || value.to_s.strip.casecmp?('true')
  end

  # Espelha o Ai::Gateway#emit: grava o ai_event na MESMA stream, com ai_run_id nil (attributes.updated
  # e memory.updated nunca setavam run_id). account_id vem da conversa (== @account.id do Gateway).
  def emit(type, payload)
    Ai::Event.create!(
      account_id: @conversation.account_id, conversation_id: @conversation.id,
      ai_run_id: nil, event_type: type, payload: payload, status: 'ok'
    )
  end
end
