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

  # Progressão DETERMINÍSTICA de etapa. O índice (additional_attributes['ai_step_index'], inteiro,
  # inicia em 0) é a FONTE DE VERDADE — não o texto que o modelo relata. O servidor decide "onde
  # estamos"; o modelo só sinaliza step_completed para AVANÇAR (+1). Nunca retrocede, nunca pula,
  # trava na última etapa. Antes, current_step era texto livre e o modelo se autolocalizava — o que
  # o fazia "esquecer" a etapa e voltar sozinho (bug recorrente em conversas reais).
  #
  # Também grava ai_step.grouping_delay_seconds (da etapa ATUAL após o avanço) p/ o MessageGrouping,
  # e ai_step.reported_name (o current_step livre do modelo) só como LOG/observabilidade — nada o
  # consome; serve para comparar o que o modelo achava vs. o índice real.
  def track_step(department, decision, dispatcher: nil, run: nil)
    steps = Array(department.playbook&.steps)
    return if steps.empty? # playbook sem etapas = no-op

    max_index = steps.size - 1
    index = current_step_index(max_index)

    # Dispara as automações da etapa ATUAL na transição de conclusão (idempotente por índice).
    fire_step_automations(decision, steps[index], index, dispatcher, run)

    # Avança só quando o modelo conclui a etapa; clamp no máximo. Nunca retrocede/pula.
    new_index = truthy?(decision['step_completed']) ? (index + 1).clamp(0, max_index) : index
    persist_step_state(steps[new_index], new_index, decision)
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

  # Índice atual da conversa (clampado no range válido do playbook). Default 0 (primeira etapa).
  def current_step_index(max_index)
    (@conversation.additional_attributes || {})['ai_step_index'].to_i.clamp(0, max_index)
  end

  # Grava o índice (fonte de verdade) + o hash ai_step (delay p/ MessageGrouping e reported_name p/ log).
  # Re-lê os atributos porque fire_step_automations / StepAutomationRunner podem tê-los mutado.
  def persist_step_state(current, new_index, decision)
    delay = step_delay(current)
    attrs = @conversation.additional_attributes || {}
    attrs['ai_step_index'] = new_index
    attrs['ai_step'] = {
      'name' => step_name(current),
      'grouping_delay_seconds' => (delay.positive? ? delay : nil),
      'reported_name' => decision['current_step'].to_s.strip.presence # só log; não é fonte de verdade
    }
    @conversation.update!(additional_attributes: attrs)
  end

  # Dispara as automações da etapa CONCLUÍDA na transição de índice. Só quando o modelo sinaliza
  # step_completed E ainda não disparamos para este índice (idempotência via ai_step_last_fired_index).
  # Marca ANTES de rodar (não reprocessa se algo demorar/falhar). Precisa do dispatcher + run (do
  # Gateway) para as ações auditadas; sem eles, não roda.
  def fire_step_automations(decision, step, index, dispatcher, run)
    return unless dispatcher && run
    return unless truthy?(decision['step_completed'])
    return if already_fired?(index)

    mark_fired(index)
    return if step_automations(step).blank?

    Ai::StepAutomationRunner.new(
      conversation: @conversation, account: @conversation.account, agent: @agent,
      dispatcher: dispatcher, run: run
    ).run(step)
  end

  # Idempotência: só dispara uma vez por índice (o avanço é monotônico, então last_fired >= index
  # significa que a etapa já disparou).
  def already_fired?(index)
    last = (@conversation.additional_attributes || {})['ai_step_last_fired_index']
    last.is_a?(Integer) && last >= index
  end

  def mark_fired(index)
    attrs = @conversation.additional_attributes || {}
    attrs['ai_step_last_fired_index'] = index
    @conversation.update!(additional_attributes: attrs)
  end

  def step_automations(step)
    Array(step && (step['automations'] || step[:automations]))
  end

  def step_name(step)
    return '' unless step.is_a?(Hash)

    (step['name'] || step[:name]).to_s.strip
  end

  def step_delay(step)
    return 0 unless step.is_a?(Hash)

    (step['group_delay_seconds'] || step[:group_delay_seconds]).to_i
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
