# Extraído do Ai::Gateway (quebra do God object — Passo 4): escreve o ESTADO DERIVADO da decisão na
# conversa/agente — atributos coletados, etapa atual (p/ o agrupamento) e o resumo rolante na memória.
# São gravações idempotentes com rescue próprio (nunca derrubam o run). Contexto injetado no initialize;
# `run_record` NÃO é necessário (só ia pro emit, que ignorava) — some das assinaturas. Emite os MESMOS
# ai_events de antes (attributes.updated / memory.updated) via emit próprio.
class Ai::StateManager
  # Camada B: nº PADRÃO de turnos parado numa etapa de slot antes de TRANSFERIR para humano, quando o
  # department não define transfer_rules['stuck_handoff_turns']. O valor real vem da tela (0 = desligado).
  # Default aplicado também às etapas de departments antigos (rede de segurança ligada por padrão).
  DEFAULT_STUCK_HANDOFF_TURNS = 3

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
  # source (default :trusted): origem da escrita. :trusted = gravadores já validados (SlotCollector,
  # worker CaptureJudge incl. o 'malformed' deliberado, anexo) — grava tudo. :supervisor = campo
  # `attributes` CRU do modelo, NÃO confiável — passa pelo gate anti-contaminação (ver gated_facts).
  # expected_step: a etapa ativa NO INÍCIO do turno (pré-avanço). O Gateway chama track_step (que avança
  # o ai_step_index) ANTES deste persist; sem o pré-avanço, o gate leria o slot da PRÓXIMA etapa e
  # descartaria o valor recém-coletado como unexpected_key (funil avança, memória vazia — a regressão do
  # #284). Só a fonte :supervisor usa; nil => fallback lê o índice (compat p/ chamadas fora do Gateway).
  def persist_attributes(attrs, department, source: :trusted, expected_step: nil)
    return unless attrs.is_a?(Hash)

    cleaned = reject_blank_values(attrs)
    return if cleaned.empty?

    # 1. Memória de fatos AO VIVO (por conversa): grava TODO dado coletado não-vazio, SEM allowlist.
    #    É o que alimenta "Dados JÁ coletados" no prompt mesmo sem CustomAttributeDefinition —
    #    evita a IA reperguntar o que já foi dito (bug do loop, conversa 350/352).
    #    Fonte :supervisor passa pelo GATE antes daqui (chave esperada + valor válido p/ tipo conhecido)
    #    para uma alucinação do modelo NÃO virar "fato" reinjetado no prompt (loop de auto-contaminação).
    persist_collected_facts(gated_facts(cleaned, department, source, expected_step))

    # 2. Espelha para custom_attributes SÓ as chaves com campo cadastrado (protege Bitrix/relatórios).
    #    Chave sem campo NÃO é mais descartada — já foi salva em ai_collected_facts acima; aqui só não
    #    há campo estruturado para espelhar (o attributes.unknown_key vira telemetria disso).
    known = filter_known_attributes(cleaned, department)
    return if known.empty?

    # 3. Normaliza valores de atributo tipo LIST para a opção CANÔNICA (só o ESPELHO; ai_collected_facts
    #    fica com o valor cru). Sem isso, "maravilha" espelhado num campo list ["Chapecó","Maravilha"]
    #    não casa no select do painel ("Selecione o valor") e um save humano pode zerar o campo (conv 367).
    known = normalize_list_values(known)

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
    return if cleaned.blank? # gate do supervisor pode zerar tudo — não grava ai_collected_facts vazio

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

  # Troca cada valor pela opção CANÔNICA quando a definição é do tipo list e o valor casa (ignorando
  # caixa/acento/espaços) com alguma attribute_values. Não casou ou não é list -> valor como veio.
  # NÃO descarta nada — só canonicaliza o espelho de custom_attributes.
  def normalize_list_values(known)
    definitions = ::CustomAttributeDefinition
                  .where(account_id: @conversation.account_id, attribute_model: :conversation_attribute,
                         attribute_key: known.keys.map(&:to_s))
                  .index_by(&:attribute_key)
    known.each_with_object({}) do |(key, value), out|
      out[key] = canonical_list_value(definitions[key.to_s], value)
    end
  rescue StandardError => e
    Rails.logger.error "[Ai::StateManager#normalize_list_values] #{e.class}: #{e.message}"
    known
  end

  # Casa por IGUALDADE normalizada (não substring): reusa Ai::SlotExtractor.normalize (mesma norma de
  # caixa/acento/espaços dos slots de choice) nos DOIS lados e exige igualdade. Substring seria perigoso
  # aqui — o valor vem de texto livre e "não é maravilha, é chapecó" casaria com "Maravilha" (cidade
  # errada). Devolve a opção exatamente como está em attribute_values, ou o valor cru se nada casar.
  def canonical_list_value(definition, value)
    return value unless definition&.list?

    target = Ai::SlotExtractor.normalize(value)
    Array(definition.attribute_values).map(&:to_s)
                                      .find { |opt| Ai::SlotExtractor.normalize(opt) == target } || value
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
  # Retorna nil normalmente; ou { stuck_handoff: {attribute, step_name, turns} } quando a etapa de slot
  # travou por N turnos (Camada B) — SINAL para o Gateway TRANSFERIR para humano (o Gateway tem o
  # action_dispatcher + handoff_coordinator; aqui só decidimos, não executamos o handoff).
  # rubocop:disable Metrics/ParameterLists -- seam de orquestração: o quê (department, decision) +
  # contexto de automação do run (dispatcher, run) + input da vez (message_text agrupado, message p/
  # anexo/idempotência). Agrupar seria só cosmético e rippla por ~9 call sites de spec + o Gateway.
  def track_step(department, decision, dispatcher: nil, run: nil, message_text: nil, message: nil, judge_result: nil)
    # rubocop:enable Metrics/ParameterLists
    steps = Array(department.playbook&.steps)
    return if steps.empty? # playbook sem etapas = no-op

    # BUG 1 (idempotência por mensagem, ATÔMICA): só o PRIMEIRO run/binding desta mensagem processa a
    # etapa — captura E avanço. Re-run/binding/re-enfileiramento da MESMA mensagem é no-op (a mesma
    # mensagem não preenche 2 slots nem re-avança, mesmo que a etapa tenha avançado no run anterior).
    # Sem message_id (follow-up/teste) => processa normal. Ver Ai::TurnCapture#claim.
    return unless turn_capture.claim(message)

    index = current_step_index(steps.size - 1)
    step = steps[index]

    # Captura desta mensagem (anexo BUG 3 -> modelo Opção B -> texto cru), no MÁXIMO um slot por mensagem
    # (a idempotência acima já garantiu que este é o 1º run). Sempre chamada — o anexo vira fato mesmo em
    # etapa sem slot; internamente é no-op se não há slot nem anexo. Devolve nil (capturou/nada),
    # :no_attempt (#269, slot de tipo conhecido sem tentativa) ou { refusal: 'not_an_answer'|'judge_failed' }
    # (worker de julgamento recusou o turno) — ver Ai::TurnCapture.
    # judge_result (camada 3): quando o Gateway já rodou o worker ANTES da decisão (p/ decidir a busca
    # de conhecimento), passa o resultado aqui para a captura REUSAR — o worker roda UMA vez por turno.
    capture_signal = turn_capture.capture(step, decision, message_text, message, department, judge_result: judge_result)

    # Conclusão + confirmação-única (Parte 3) + rede de segurança contra travamento (Camada B/#259). Nem
    # :no_attempt nem a recusa do juiz contam o contador NORMAL (cliente engajado); a recusa do juiz tem
    # um contador SEPARADO com teto próprio (ver resolve_empty_slot / resolve_judge_refusal).
    outcome = step_resolver.resolve_completion(step, decision, stuck_handoff_limit(department), index, capture_signal)

    # Dispara as automações da etapa ATUAL na MESMA condição de conclusão determinística (idempotente
    # por índice). Antes era gated no step_completed cru do modelo — o que faria as automações PARAREM
    # de disparar em etapas com avanço por slot (step_completed pode ser false quando o código avança).
    fire_step_automations(outcome[:completed], step, index, dispatcher, run)
    persist_progress(steps, index, outcome, decision)

    # Camada B: NÃO força avanço (dado faltando). outcome[:signal] leva o pedido de handoff ao Gateway.
    outcome[:signal]
  rescue StandardError => e
    Rails.logger.error "[Ai::StateManager#track_step] #{e.class}: #{e.message}"
    nil
  end

  # Persiste o avanço da etapa (clamp no máximo; nunca retrocede/pula) + o contador de trava. Extraído
  # do track_step (mantém-no enxuto). O contador zera ao avançar/transferir e incrementa ao permanecer.
  def persist_progress(steps, index, outcome, decision)
    new_index = outcome[:completed] ? (index + 1).clamp(0, steps.size - 1) : index
    persist_step_state(steps[new_index], new_index, decision)
    persist_stuck_turns(outcome[:stuck])
    persist_slot_refusals(outcome[:refusals])
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

  # (Camada 3) Reivindica o turno ANTES do track_step, reusando o MESMO turn_capture memoizado. Assim o
  # worker que roda antes da decisão fica DENTRO da proteção de idempotência do BUG 1: se este run perder
  # o claim (re-execução do job / 2º binding / concorrência), devolve false e o Gateway NÃO roda o worker.
  # Depois, o claim dentro do track_step reencontra o id em @claimed e devolve TRUE (already-won, no-op —
  # sem 2º UPDATE atômico), então o track_step NÃO aborta e PERSISTE o índice. Ver Ai::TurnCapture#claim.
  def claim_turn(message)
    turn_capture.claim(message)
  end

  # (Camada 3) Etapa corrente (hash do playbook) p/ o Gateway decidir a busca de conhecimento e rodar o
  # worker. Mesmo índice que o track_step usará (nada avança entre aqui e lá). nil quando não há etapas.
  def current_step(department)
    steps = Array(department.playbook&.steps)
    return nil if steps.empty?

    steps[current_step_index(steps.size - 1)]
  end

  # (Camada 3) Roda o worker de julgamento UMA vez por turno — serve p/ (a) a intenção (asks_about/query,
  # decide a busca) e (b) a captura (reusado no track_step via judge_result). nil quando o worker está
  # DESLIGADO (default) ou sem texto -> Gateway mantém o RAG de hoje (comportamento inalterado).
  def run_turn_judge(step, message_text)
    return nil unless judge_enabled?
    return nil if message_text.to_s.strip.empty?

    # step pode ser nil (department sem playbook): o worker ainda classifica a INTENÇÃO (asks_about);
    # a captura só usa o julgamento quando há slot. slot nil quando não há etapa.
    slot = step ? Ai::StepSlot.required_attribute(step) : nil
    Ai::Workers::CaptureJudge.judge(step: step, slot: slot, message_text: message_text,
                                    profile: @agent&.operation_profile, conversation: @conversation)
  end

  # Worker de captura opt-in ligado? (when_silent/always). 'off' (default) => Gateway não roda o worker
  # (RAG de hoje, todo turno) e NÃO reivindica o turno cedo (claim segue dentro do track_step).
  def judge_enabled?
    %w[when_silent always].include?(@agent&.operation_profile&.worker(:capture_judge)&.dig('mode').to_s)
  end

  private

  # Índice atual da conversa (clampado no range válido do playbook). Default 0 (primeira etapa).
  def current_step_index(max_index)
    (@conversation.additional_attributes || {})['ai_step_index'].to_i.clamp(0, max_index)
  end

  # Colaborador da captura do turno (BUG 1 idempotência atômica + BUG 3 anexo + Opção B). Memoizado
  # por run (mesma instância do StateManager) -> mantém o guard em memória do claim. Persiste por aqui.
  def turn_capture
    @turn_capture ||= Ai::TurnCapture.new(conversation: @conversation, persister: self, agent: @agent)
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
  # Decisão de conclusão da etapa (confirmação-única + rede #259 + teto de recusas do juiz). Colaborador
  # PURO (não persiste) — o StateManager grava o outcome em persist_progress. Memoizado por run.
  def step_resolver
    @step_resolver ||= Ai::StepResolver.new(conversation: @conversation)
  end

  # Limite de turnos parado antes de transferir (Camada B), da config do agente (tela). Chave ausente =>
  # DEFAULT_STUCK_HANDOFF_TURNS (rede ligada por padrão, inclusive p/ departments antigos); 0 = desligado.
  def stuck_handoff_limit(department)
    rules = department.transfer_rules || {}
    rules.key?('stuck_handoff_turns') ? rules['stuck_handoff_turns'].to_i : DEFAULT_STUCK_HANDOFF_TURNS
  end

  # Read-modify-write só da chave do contador, lendo FRESCO (após persist_step_state gravar o índice)
  # — preserva ai_step_index/ai_collected_facts, mesma disciplina de concorrência dos demais writes.
  # Só grava quando muda (evita write à toa quando já está em 0 e permanece em 0).
  def persist_stuck_turns(count)
    attrs = @conversation.additional_attributes || {}
    return if attrs['ai_step_stuck_turns'].to_i == count

    attrs['ai_step_stuck_turns'] = count
    @conversation.update!(additional_attributes: attrs)
  end

  # Contador SEPARADO de recusas consecutivas do juiz (ai_slot_refusals). nil no outcome => não mexe
  # (só os caminhos que sabem o valor o informam: captura zera; recusa acumula/estoura). Mesma
  # disciplina do persist_stuck_turns (só grava quando muda).
  def persist_slot_refusals(count)
    return if count.nil?

    attrs = @conversation.additional_attributes || {}
    return if attrs['ai_slot_refusals'].to_i == count

    attrs['ai_slot_refusals'] = count
    @conversation.update!(additional_attributes: attrs)
  end

  # Dispara as automações da etapa CONCLUÍDA na transição de índice. Só quando a etapa foi concluída
  # (mesma condição determinística do avanço — ver #step_completed?) E ainda não disparamos para este
  # índice (idempotência via ai_step_last_fired_index). Só MARCA quando há automação a rodar — uma etapa
  # SEM automação não grava last_fired (senão o already_fired? bloquearia para sempre uma automação
  # adicionada depois, sobretudo na última etapa, onde o índice não avança pelo clamp). Marca ANTES de
  # rodar (não reprocessa se algo demorar/falhar). Precisa do dispatcher + run (do Gateway); sem eles, não roda.
  def fire_step_automations(completed, step, index, dispatcher, run)
    return unless dispatcher && run
    return unless completed
    return if already_fired?(index)
    return if step_automations(step).blank?

    mark_fired(index)
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

  # GATE anti-contaminação da memória de fatos (fonte :supervisor). O campo `attributes` do modelo é
  # NÃO confiável: sem filtro, uma alucinação (ex.: {"plano":"Premium"} que o cliente nunca disse)
  # virava "fato" em ai_collected_facts e reentrava no prompt do turno seguinte como "Dados já
  # coletados", envenenando toda a conversa. Mantém só chaves ESPERADAS (lead_variables ∪ atributos de
  # conversa da conta ∪ slot da etapa atual) e, para tipos de formato conhecido, só valores que passam
  # no Ai::SlotExtractor. Fonte :trusted devolve o hash inalterado (regressão zero). Só filtra o que
  # entra em ai_collected_facts — o espelho em custom_attributes segue igual (filter_known_attributes).
  def gated_facts(cleaned, department, source, expected_step = nil)
    return cleaned unless source == :supervisor

    # A etapa avaliada é a PRÉ-AVANÇO (expected_step, passada pelo Gateway antes do track_step avançar o
    # índice). Sem ela, current_slot leria o índice JÁ avançado e o slot recém-coletado cairia como
    # unexpected_key. Fallback (expected_step nil) mantém a leitura por índice p/ chamadas sem o Gateway.
    slot, step = expected_step.is_a?(Hash) ? [Ai::StepSlot.attribute(expected_step), expected_step] : current_slot(department)
    expected = supervisor_expected_keys(department, slot)
    cleaned.each_with_object({}) do |(key, value), out|
      reason = supervisor_fact_reason(key, value, expected, slot, step)
      if reason
        emit('facts.rejected', { attribute: key.to_s, reason: reason })
      else
        out[key] = value
      end
    end
  end

  # Conjunto de chaves que o supervisor PODE gravar como fato: atributos de conversa da conta (mesma
  # resolução do filter_known_attributes) + lead_variables do department + o slot da etapa atual.
  def supervisor_expected_keys(department, slot)
    keys = fillable_attribute_keys(department) + lead_variable_keys(department)
    keys << slot.to_s if slot.present?
    keys
  end

  # Nomes das lead_variables do department (a CHAVE que o prompt pede no campo `attributes`). [] em erro.
  def lead_variable_keys(department)
    return [] unless department.respond_to?(:lead_variables)

    department.lead_variables.to_a.map { |v| v.name.to_s }
  rescue StandardError => e
    Rails.logger.error "[Ai::StateManager#lead_variable_keys] #{e.class}: #{e.message}"
    []
  end

  # Slot + step da etapa ATUAL (índice = ai_step_index, mesma leitura de current_step_index/PromptCompiler).
  # [nil, nil] quando o department não tem playbook com etapas.
  def current_slot(department)
    steps = Array(department&.playbook&.steps)
    return [nil, nil] if steps.empty?

    step = steps[(@conversation.additional_attributes || {})['ai_step_index'].to_i.clamp(0, steps.size - 1)]
    [Ai::StepSlot.attribute(step), step]
  end

  # Motivo de rejeição de um fato do supervisor, ou nil (aceito). 'unexpected_key' = chave fora do
  # conjunto esperado; 'invalid_value' = tipo de formato conhecido cujo valor não passa no extractor.
  # Chave esperada de tipo livre (text/derivável nil) é aceita (não há formato para validar).
  def supervisor_fact_reason(key, value, expected, slot, step)
    return 'unexpected_key' unless expected.include?(key.to_s)

    type = supervisor_fact_type(key, slot, step)
    return nil unless Ai::SlotExtractor.known_format?(type)

    options = key.to_s == slot.to_s ? Ai::StepSlot.options(step) : []
    Ai::SlotExtractor.extract(attribute_type: type, text: value.to_s, options: options).blank? ? 'invalid_value' : nil
  end

  # Tipo do fato: o slot da etapa atual usa effective_type (collect.type ou derivado da chave); as demais
  # chaves derivam só do NOME via type_for_key. nil/'text' => tipo livre (sem validação de formato).
  def supervisor_fact_type(key, slot, step)
    if step && key.to_s == slot.to_s
      Ai::SlotCollector.new(conversation: @conversation).effective_type(step, slot)
    else
      Ai::SlotExtractor.type_for_key(key)
    end
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
