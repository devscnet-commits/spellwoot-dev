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
  # SÓ grava chaves que batem com um attribute_key REAL (mesma fonte do fillable_attributes do prompt:
  # definições da conta menos as desabilitadas pelo department). Antes era merge cego — o modelo devolver
  # uma chave livre (ex.: "cidade_usuario" em vez de "cidade") gravava lixo solto no JSON e o campo real
  # ficava vazio (perda silenciosa de dado). Chave desconhecida NÃO persiste e emite attributes.unknown_key
  # (observabilidade, mesmo padrão do decision.unknown_kind). Merge, ignora vazios e no-ops.
  def persist_attributes(attrs, department)
    return unless attrs.is_a?(Hash)

    cleaned = reject_blank_values(attrs)
    return if cleaned.empty?

    # 1. Memória de fatos AO VIVO (por conversa): grava TODO dado coletado não-vazio, SEM allowlist.
    #    É o que alimenta "Dados JÁ coletados" no prompt mesmo sem CustomAttributeDefinition —
    #    evita a IA reperguntar o que já foi dito (bug do loop, conversa 350/352).
    persist_collected_facts(cleaned)

    # 2. Espelha para custom_attributes SÓ as chaves com campo cadastrado (protege Bitrix/relatórios).
    #    Chave sem campo NÃO é mais descartada — já foi salva em ai_collected_facts acima; aqui só não
    #    há campo estruturado para espelhar (o attributes.unknown_key vira telemetria disso).
    known = filter_known_attributes(cleaned, department)
    return if known.empty?

    merged = (@conversation.custom_attributes || {}).merge(known)
    return if merged == @conversation.custom_attributes

    @conversation.update!(custom_attributes: merged)
    emit('attributes.updated', { keys: known.keys })
  rescue StandardError => e
    Rails.logger.error "[Ai::StateManager#persist_attributes] #{e.class}: #{e.message}"
  end

  # Memória de fatos coletados ao vivo (additional_attributes['ai_collected_facts']), sem allowlist.
  # Read-modify-write do hash INTEIRO, lendo additional_attributes o mais TARDE possível (não reusar
  # leitura antiga) — track_step/persist_step_state gravam no MESMO campo neste run, então a leitura
  # fresca aqui preserva ai_step_index/ai_step (senão o último write clobbaria o outro).
  #
  # PREMISSA (frágil se o fluxo mudar): a segurança deste read-modify-write depende de rodar no MESMO
  # processo/objeto que track_step, EM SEQUÊNCIA (gateway: track_step -> persist_attributes, mesmo
  # state_manager memoizado). Se um dia persist_attributes virar ASYNC (fila), OU houver um
  # @conversation.reload entre as chamadas, OU dois runs concorrentes na MESMA conversa (dois workers
  # Sidekiq), o "último update! vence" vira race e pode perder ai_step_index ou ai_collected_facts —
  # aí migrar para update ATÔMICO de jsonb no Postgres (jsonb_set) em vez do read-modify-write do hash.
  def persist_collected_facts(cleaned)
    attrs = @conversation.additional_attributes || {}
    facts = (attrs['ai_collected_facts'] || {}).merge(cleaned)
    return if facts == attrs['ai_collected_facts']

    attrs['ai_collected_facts'] = facts
    @conversation.update!(additional_attributes: attrs)
  end

  def reject_blank_values(attrs)
    attrs.reject { |_k, v| v.to_s.strip.empty? }
  end

  # Mantém só as chaves que batem com um attribute_key real; as demais NÃO entram no JSON e viram
  # attributes.unknown_key (observabilidade). Retorna o Hash das chaves válidas.
  def filter_known_attributes(cleaned, department)
    valid_keys = fillable_attribute_keys(department)
    known, unknown = cleaned.partition { |k, _v| valid_keys.include?(k.to_s) }
    unknown.each { |k, v| emit('attributes.unknown_key', { key: k.to_s, value: v.to_s.first(200) }) }
    known.to_h
  end

  # Chaves de atributo de CONVERSA que a IA pode preencher — espelha o Ai::ContextBuilder#fillable_attributes
  # (definições da conta menos as desabilitadas pelo department). É o allowlist do persist_attributes.
  def fillable_attribute_keys(department)
    disabled = Array(department&.behavior.to_h['disabled_custom_attributes'])
    ::CustomAttributeDefinition
      .where(account_id: @conversation.account_id, attribute_model: :conversation_attribute)
      .where.not(attribute_key: disabled)
      .pluck(:attribute_key)
      .map(&:to_s)
  rescue StandardError => e
    Rails.logger.error "[Ai::StateManager#fillable_attribute_keys] #{e.class}: #{e.message}"
    []
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
    step = steps[index]

    # Conclusão DETERMINÍSTICA: se a etapa declara um slot obrigatório (collect), o CÓDIGO decide
    # (slot preenchido) — não o palpite do modelo. Etapa informativa (sem slot) avança pelo sinal
    # step_completed. Etapas antigas (sem collect/complete_when) => sinal do modelo (compat). Ver #step_completed?.
    completed = step_completed?(step, decision)

    # Dispara as automações da etapa ATUAL na MESMA condição de conclusão determinística (idempotente
    # por índice). Antes era gated no step_completed cru do modelo — o que faria as automações PARAREM
    # de disparar em etapas com avanço por slot (step_completed pode ser false quando o código avança).
    fire_step_automations(completed, step, index, dispatcher, run)

    # Avança só quando a etapa conclui; clamp no máximo. Nunca retrocede/pula.
    new_index = completed ? (index + 1).clamp(0, max_index) : index
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

  # Conclusão DETERMINÍSTICA da etapa atual (código decide o avanço, não o modelo):
  #  - etapa com slot obrigatório (collect.attribute) -> concluída quando o slot está PREENCHIDO. O
  #    valor pode vir do turno ATUAL (decision['attributes'], que ainda NÃO foi persistido — track_step
  #    roda ANTES de persist_attributes no Gateway) OU de fatos já gravados (ai_collected_facts). Por
  #    isso checamos os dois, com prioridade para o valor do turno (senão o avanço atrasaria 1 turno =
  #    a repergunta que queremos matar).
  #  - complete_when == 'always' (etapa informativa, sem coleta) -> avança pelo sinal do modelo.
  #  - sem collect e sem complete_when (etapas antigas) -> sinal do modelo (compat total, zero migração).
  def step_completed?(step, decision)
    slot = required_slot(step)
    return truthy?(decision['step_completed']) if step_criterion(step) == 'always'
    return slot_filled?(slot, decision) if slot

    truthy?(decision['step_completed'])
  end

  # Chave do slot que ESTA etapa coleta, se declarada e obrigatória. Default: obrigatória quando
  # collect existe (required só desliga se vier explicitamente falso). nil quando não coleta nada.
  def required_slot(step)
    return nil unless step.is_a?(Hash)

    collect = step['collect'] || step[:collect]
    return nil unless collect.is_a?(Hash)

    key = (collect['attribute'] || collect[:attribute]).to_s.strip
    return nil if key.empty? || slot_optional?(collect)

    key
  end

  # collect.required só DESLIGA a obrigatoriedade se vier explicitamente falso; ausente => obrigatório.
  def slot_optional?(collect)
    required = collect.key?('required') ? collect['required'] : collect[:required]
    !required.nil? && !truthy?(required)
  end

  def step_criterion(step)
    return '' unless step.is_a?(Hash)

    (step['complete_when'] || step[:complete_when]).to_s.strip
  end

  # O slot está preenchido? Prioriza o valor recém-devolvido pelo modelo NESTE turno (decision,
  # ainda não persistido), depois os fatos já gravados. Preserva false/0 como preenchidos.
  def slot_filled?(slot, decision)
    pending = decision['attributes']
    return true if pending.is_a?(Hash) && pending[slot].to_s.strip.present?

    facts = (@conversation.additional_attributes || {})['ai_collected_facts']
    facts.is_a?(Hash) && facts[slot].to_s.strip.present?
  end

  # Dispara as automações da etapa CONCLUÍDA na transição de índice. Só quando a etapa foi concluída
  # (mesma condição determinística do avanço — ver #step_completed?) E ainda não disparamos para este
  # índice (idempotência via ai_step_last_fired_index). Marca ANTES de rodar (não reprocessa se algo
  # demorar/falhar). Precisa do dispatcher + run (do Gateway) para as ações auditadas; sem eles, não roda.
  def fire_step_automations(completed, step, index, dispatcher, run)
    return unless dispatcher && run
    return unless completed
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
