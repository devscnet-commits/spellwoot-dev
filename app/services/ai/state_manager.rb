# Extraído do Ai::Gateway (quebra do God object — Passo 4): escreve o ESTADO DERIVADO da decisão na
# conversa/agente — atributos coletados, etapa atual (p/ o agrupamento) e o resumo rolante na memória.
# São gravações idempotentes com rescue próprio (nunca derrubam o run). Contexto injetado no initialize;
# `run_record` NÃO é necessário (só ia pro emit, que ignorava) — some das assinaturas. Emite os MESMOS
# ai_events de antes (attributes.updated / memory.updated) via emit próprio.
class Ai::StateManager
  # Gap 4: TETO ABSOLUTO de turnos por etapa antes de TRANSFERIR (o campo da tela "travar por X mensagens").
  # Conta TODO turno não-produtivo (recusa/:no_attempt/confirmação/vazio), não só as tentativas frustradas.
  # Como absoluto, 3 era agressivo (3 perguntas transferia) -> default 10. 0 = desligado. Valor real vem da
  # tela. A rede de recusa (mais cedo) deriva daqui (metade). Migração sobe os 3 antigos -> 10.
  DEFAULT_STUCK_HANDOFF_TURNS = 10

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
  # Devolve o subconjunto que SOBREVIVEU ao gate (o que de fato entrou em ai_collected_facts). O chamador
  # usa isso para saber o que persistiu — o Ai::TurnCapture#persist_judged só emite slot.captured para a
  # chave sobrevivente (senão registraria "captured" sem gravar). Para :trusted, gated == cleaned (o gate
  # é no-op), então nada muda para os chamadores antigos. {} quando não há nada a gravar / em erro.
  def persist_attributes(attrs, department, source: :trusted, expected_step: nil)
    return {} unless attrs.is_a?(Hash)

    cleaned = reject_blank_values(attrs)
    return {} if cleaned.empty?

    # 1. Memória de fatos AO VIVO (por conversa): grava TODO dado coletado não-vazio, SEM allowlist.
    #    É o que alimenta "Dados JÁ coletados" no prompt mesmo sem CustomAttributeDefinition —
    #    evita a IA reperguntar o que já foi dito (bug do loop, conversa 350/352).
    #    Fonte :supervisor passa pelo GATE (chave esperada + valor válido p/ tipo conhecido) para uma
    #    alucinação do modelo — ou um "answered" do juiz de tipo errado — NÃO virar fato/espelho.
    gated = gated_facts(cleaned, department, source, expected_step)
    persist_collected_facts(gated)
    persist_slot_feedback(gated) # (4) registra/limpa o "último valor rejeitado por formato" p/ o prompt explicar

    # Frente C: espelha os MESMOS fatos gateados na memória do CONTATO (Ai::CustomerMemory.key_facts) —
    # cross-conversa, cross-agente. SEM allowlist (ao contrário do espelho de custom_attributes abaixo): nome/
    # CPF vivem na memória mesmo sem CustomAttributeDefinition (a conta não tem). Determinístico, SEM LLM, na
    # CAPTURA (mesmo-turno: uma correção atualiza a memória no ato, não espera o resolve). Ausência
    # (__sem_valor__) NUNCA sobe — é da conversa, não do cliente. Fica ANTES do early-return do bloco 2.
    mirror_contact_facts(gated)

    # 2. Espelha para custom_attributes SÓ as chaves com campo cadastrado (protege Bitrix/relatórios).
    #    Espelha a partir do conjunto GATEADO (não do cru): o que o gate rejeitou não vai para facts NEM
    #    para o painel — uma porta, um cadeado (p/ :trusted, gated == cleaned, comportamento inalterado).
    # Gap 1: o token/valor de ausência NUNCA espelha em custom_attributes (ele vive só em ai_collected_facts,
    # gravado pelo fill_absent). Um token vazado corromperia silenciosa e indistinguivelmente o dado do operador.
    known = filter_known_attributes(gated, department).reject { |_k, v| Ai::SlotAbsence.absence_value?(v) }
    return gated if known.empty?

    # 3. Normaliza valores de atributo tipo LIST para a opção CANÔNICA (só o ESPELHO; ai_collected_facts
    #    fica com o valor cru). Sem isso, "maravilha" espelhado num campo list ["Chapecó","Maravilha"]
    #    não casa no select do painel ("Selecione o valor") e um save humano pode zerar o campo (conv 367).
    known = normalize_list_values(known)

    merged = (@conversation.custom_attributes || {}).merge(known)
    return gated if merged == @conversation.custom_attributes

    @conversation.update!(custom_attributes: merged)
    emit('attributes.updated', { keys: known.keys })
    gated
  rescue StandardError => e
    Rails.logger.error "[Ai::StateManager#persist_attributes] #{e.class}: #{e.message}"
    {}
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

  # (4) FEEDBACK DE REJEIÇÃO POR FORMATO — só OBSERVA (o motor de validação, supervisor_fact_reason, é intocado).
  # Guarda o último {slot, value} barrado por invalid_value neste turno em ai_last_invalid, para o PromptCompiler
  # dizer à IA POR QUE rejeitou (em vez de repetir a mesma pergunta). Limpa quando o slot outrora inválido é
  # finalmente ACEITO (entra em `gated`). Genérico: vale para todo tipo de formato (cpf/email/phone/number/choice).
  def persist_slot_feedback(gated)
    attrs = @conversation.additional_attributes || {}
    before = attrs['ai_last_invalid']
    changed = false
    if before.is_a?(Hash) && gated.key?(before['slot'].to_s) # slot outrora inválido finalmente aceito -> limpa
      attrs.delete('ai_last_invalid')
      changed = true
    end
    if @rejected_invalid.present?
      slot, value = @rejected_invalid.first # um slot por turno na prática; a última rejeição vence
      new_val = { 'slot' => slot.to_s, 'value' => value.to_s }
      if attrs['ai_last_invalid'] != new_val
        attrs['ai_last_invalid'] = new_val
        changed = true
      end
    end
    @conversation.update!(additional_attributes: attrs) if changed
  end

  # Frente C: memória por CONTATO (Ai::CustomerMemory.key_facts), cross-conversa e cross-agente. Espelha os
  # fatos GATEADOS não-ausência, ÚLTIMA-VENCE por chave (merge; chave não tocada é preservada). SEM allowlist
  # de CustomAttributeDefinition — o contato guarda tudo o que o motor capturou. NÃO gera summary (isso é o
  # customer_memory_updater no resolve, via LLM); aqui é só o DADO. No-op sem contato, sem fato real, ou quando
  # nada muda. O summary/conversations_count ficam com o updater — este método só toca key_facts.
  # Read-modify-write da linha do contato: duas conversas SIMULTÂNEAS do MESMO contato podem competir (último
  # save vence) — raro (mesmo contato, dois atendimentos ao vivo) e aditivo (mesmas chaves, mesma pessoa).
  def mirror_contact_facts(gated)
    return unless @conversation.contact_id

    facts = gated.reject { |_k, v| Ai::SlotAbsence.absence_value?(v) }
    return if facts.empty?

    memory = Ai::CustomerMemory.find_or_initialize_by(contact_id: @conversation.contact_id,
                                                      account_id: @conversation.account_id)
    merged = memory.key_facts.to_h.merge(facts)
    return if merged == memory.key_facts

    memory.key_facts = merged
    memory.last_updated_at = Time.current
    memory.save!
  rescue StandardError => e
    Rails.logger.error "[Ai::StateManager#mirror_contact_facts] #{e.class}: #{e.message}"
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
    # Gap 4 v2 (conserto conv 394): o turno foi PRODUTIVO (o cliente perguntou algo legítimo e a IA
    # respondeu)? Se sim, não conta no teto improdutivo. Bool derivado aqui e passado ao StepResolver —
    # NÃO vaza judge_result para o resolver.
    productive = productive_turn?(judge_result, decision)
    # (b)-core: se a etapa corrente é terminal com desfecho declarado (on_complete, sem slot), calcula AQUI
    # — o StateManager tem o array de steps — se os obrigatórios ATÉ o índice estão preenchidos (a fronteira
    # ≤ índice permite conclusão de RAMO no meio do playbook). O resolver decide o quarto bucket com isso.
    conclude_ready = conclude_ready?(steps, index, step)
    # (item 5) O avanço passa a ler o VEREDITO do gate para o valor cru do slot, não o cru presente. Calculado
    # AQUI (antes do gate rodar de fato no Gateway, gateway.rb:204, DEPOIS do track_step) com os MESMOS
    # métodos do gate — mesmo julgamento, sem reordenar. Passado ao resolver como slot_valid.
    slot_valid = supervisor_slot_valid?(department, step, decision)
    outcome = step_resolver.resolve_completion(step, decision, stuck_handoff_limit(department), index, capture_signal, productive,
                                               conclude_ready: conclude_ready, slot_valid: slot_valid)
    emit('conclusion.not_ready', { step_index: index }) if outcome[:conclude_blocked]

    # Dispara as automações da etapa ATUAL na MESMA condição de conclusão determinística (idempotente
    # por índice). Antes era gated no step_completed cru do modelo — o que faria as automações PARAREM
    # de disparar em etapas com avanço por slot (step_completed pode ser false quando o código avança).
    fire_step_automations(outcome[:completed], step, index, dispatcher, run)
    # Gap 1: slot OPCIONAL declinado -> grava a sentinela de ausência SÓ em ai_collected_facts (via
    # persist_collected_facts, NÃO persist_attributes) para o token NUNCA espelhar em custom_attributes/
    # Bitrix/Meta. Assim o slot conta como preenchido (não repergunta) e o avanço já veio no outcome.
    persist_collected_facts({ outcome[:fill_absent].to_s => Ai::StepSlot::ABSENT }) if outcome[:fill_absent]
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
    persist_step_turns(outcome[:turns])
    persist_step_questions(outcome[:questions])
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

  # (Approach 1a) PRÓXIMA etapa (index+1) — usada SÓ pelo Gateway p/ o look-ahead de conhecimento: buscar o
  # catálogo da etapa que ENTRA no turno da transição (o resolve_knowledge usava a etapa pré-avanço, então
  # ao entrar em PLANOS o catálogo só vinha um turno depois — conv 393). nil na última etapa/sem etapas.
  # Leitura pura, NÃO avança nada, e é SEPARADA do current_step de propósito: gate de atributos e juiz
  # seguem no pré-avanço (ao contrário do Gap 2, aqui só o conhecimento olha a etapa de destino).
  def next_step(department)
    steps = Array(department.playbook&.steps)
    return nil if steps.empty?

    steps[current_step_index(steps.size - 1) + 1]
  end

  # 3ª guarda do TrivialTurnGate: a etapa CORRENTE está pronta para CONCLUIR (terminal com on_complete +
  # obrigatórios preenchidos)? Em etapa terminal pronta, um "ok" é o ACEITE da transição — o turno que
  # DISPARA a conclusão determinística — não ruído; o gate não pode engoli-lo (senão a conversa fica parada
  # sem transferir). NÃO dispara em terminal com obrigatório faltando (conclude_ready? = false) — ali "ok" é
  # ruído e PULA; por isso a guarda é conclude_ready?, não "declara on_complete".
  #
  # MESMO ESTADO Camada 0 (gate, ANTES do track_step) × Camada 1 (resolver, no track_step): reusa o MESMO
  # conclude_ready? do (b)-core, com os MESMOS inputs (steps, index=ai_step_index pré-avanço, ai_collected_facts).
  # O turno que aciona esta guarda é TRIVIAL ("ok"): não captura nada (a guarda (c) pending_slot já barrou
  # qualquer slot pendente antes de chegar aqui) e não avança o índice — então os facts e o índice lidos aqui
  # são idênticos aos que o resolver leria. Mesmo método + mesmos inputs => mesmo veredito (sem gate/resolver
  # discordando), o mesmo cuidado do item 5 (slot_filled? reusa supervisor_slot_valid?).
  def conclude_ready_for_current?(department)
    steps = Array(department&.playbook&.steps)
    return false if steps.empty?

    index = current_step_index(steps.size - 1)
    conclude_ready?(steps, index, steps[index])
  end

  # (Camada 3) Roda o worker de julgamento UMA vez por turno — serve p/ (a) a intenção (asks_about/query,
  # decide a busca) e (b) a captura (reusado no track_step via judge_result). nil quando o worker está
  # DESLIGADO (default) ou sem texto -> Gateway mantém o RAG de hoje (comportamento inalterado).
  def run_turn_judge(step, message_text)
    return nil unless judge_enabled?
    return nil if message_text.to_s.strip.empty?

    # step pode ser nil (department sem playbook): o worker ainda classifica a INTENÇÃO (asks_about);
    # a captura só usa o julgamento quando há slot. Gap 2: attribute (não required_attribute) para o juiz
    # enxergar o slot também quando OPCIONAL. slot nil quando não há etapa/slot.
    slot = step ? Ai::StepSlot.attribute(step) : nil
    Ai::Workers::CaptureJudge.judge(step: step, slot: slot, message_text: message_text,
                                    profile: @agent&.operation_profile, conversation: @conversation)
  end

  # Worker de captura opt-in ligado? (when_silent/always). 'off' (default) => Gateway não roda o worker
  # (RAG de hoje, todo turno) e NÃO reivindica o turno cedo (claim segue dentro do track_step).
  def judge_enabled?
    %w[when_silent always].include?(@agent&.operation_profile&.worker(:capture_judge)&.dig('mode').to_s)
  end

  # (Contrato pergunta↔etapa) Conjunto de chaves que um asked_slot do modelo PODE nomear: os slots
  # (declarados ∪ inferidos) de TODAS as etapas do playbook ∪ lead_variables ∪ atributos de conversa
  # preenchíveis. Reusa os MESMOS coletores do gate anti-contaminação (lead_variable_keys /
  # fillable_attribute_keys) em vez de duplicar. Um asked_slot fora daqui é chave fantasma — o
  # Ai::TurnCapture o ignora (fallback pro slot da etapa) para não envenenar ai_collected_facts.
  def known_slot_keys(department)
    step_slots = Array(department&.playbook&.steps).filter_map { |s| Ai::StepSlot.attribute(s) }
    (step_slots + lead_variable_keys(department) + fillable_attribute_keys(department)).map(&:to_s).uniq
  end

  private

  # Índice atual da conversa (clampado no range válido do playbook). Default 0 (primeira etapa).
  def current_step_index(max_index)
    (@conversation.additional_attributes || {})['ai_step_index'].to_i.clamp(0, max_index)
  end

  # (b)-core: a etapa terminal com on_complete pode concluir? TODOS os slots OBRIGATÓRIOS das etapas ATÉ o
  # índice (inclusive) preenchidos em ai_collected_facts, ABSENT-aware — obrigatório vazio/ABSENT BLOQUEIA;
  # opcional NÃO gateia (ABSENT conta como preenchido, coerente com o resolve_declined). Só avalia quando a
  # etapa corrente declara on_complete e não tem slot (barato e escopado ao índice atual — nunca conclui cedo,
  # o gatilho é a etapa ter sido ALCANÇADA). Fronteira ≤ índice: conclusão de RAMO no meio do playbook.
  def conclude_ready?(steps, index, step)
    return false unless step.is_a?(Hash) && (step['on_complete'] || step[:on_complete])
    return false unless Ai::StepSlot.attribute(step).nil?

    facts = (@conversation.additional_attributes || {})['ai_collected_facts'] || {}
    Array(steps)[0..index].all? do |s|
      slot = Ai::StepSlot.attribute(s)
      next true unless slot && !Ai::StepSlot.optional?(s) # só obrigatórios gateiam a conclusão

      value = facts[slot.to_s]
      value.present? && !Ai::SlotAbsence.absence_value?(value)
    end
  rescue StandardError => e
    Rails.logger.error "[Ai::StateManager#conclude_ready?] #{e.class}: #{e.message}"
    false
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
    # Contrato pergunta↔etapa: guarda o slot que a reply_text DESTE turno pediu, para o PRÓXIMO turno
    # rotear a resposta do cliente ao slot certo. Ai::TurnCapture#capture LÊ este valor ANTES desta
    # gravação (ordem no Gateway: track_step -> capture ... -> persist_progress -> persist_step_state),
    # então a captura sempre enxerga o asked_slot do turno ANTERIOR — sem auto-referência.
    #
    # ATRIBUIÇÃO INCONDICIONAL (hotfix da regressão #304/conv 397): o estado NÃO pode sobreviver ao turno
    # que o produziu. asked_slot vem "" JUSTAMENTE nos turnos em que o modelo capturou algo (ele não está
    # perguntando um dado); preservar o valor anterior deixava o ai_last_asked_slot velho, nunca limpo,
    # e a guarda de confirmação disparava falso-positivo em slot antigo já preenchido. Presente grava; ""
    # ou ausente REMOVE a chave.
    # Limpa também quando o slot perguntado JÁ RESOLVEU como AUSÊNCIA (declínio/rejeição-para-token) neste
    # turno — o fill_absent rodou antes (persist_progress), então attrs['ai_collected_facts'] já tem o token.
    # Sem isto, o ponteiro fica apontando um slot FECHADO e o próximo turno roteia resposta de OUTRO assunto
    # para ele (conv da evidência: email_cliente declinado + "10" de vencimento -> email="10"). NÃO limpa no
    # preenchido com valor REAL: a guarda de confirmação-única (TurnCapture, fact_present?) PRECISA do ponteiro
    # para reconhecer o turno de confirmação ("confirme UMA vez") — e ausência já não dispara essa guarda.
    remember_asked_slot(attrs, decision, current)
    @conversation.update!(additional_attributes: attrs)
  end

  # Guarda o par (slot perguntado + valor proposto) deste turno, para o PRÓXIMO turno rotear/confirmar.
  # ATRIBUIÇÃO INCONDICIONAL (hotfix #304/conv 397): o estado NÃO sobrevive ao turno que o produziu — asked_slot
  # vem "" justamente nos turnos em que o modelo capturou algo; preservar o valor velho fazia a guarda de
  # confirmação disparar em slot já preenchido. Presente grava; "" ou ausência-resolvida REMOVE.
  # Frente B: o valor PROPOSTO vive SÓ ao lado de um asked_slot, mesma disciplina incondicional — senão um
  # "sim" de outro assunto confirmaria uma proposta velha.
  def remember_asked_slot(attrs, decision, step)
    asked = decision['asked_slot'].to_s.strip
    if asked.present? && !asked_slot_absent?(attrs, asked)
      attrs['ai_last_asked_slot'] = asked
      proposed = decision['proposed_value'].to_s.strip
      proposed = seed_proposed_from_memory(attrs, step, asked) if proposed.blank? # PR3 (Frente C)
      proposed.present? ? (attrs['ai_last_proposed_value'] = proposed) : attrs.delete('ai_last_proposed_value')
    else
      attrs.delete('ai_last_asked_slot')
      attrs.delete('ai_last_proposed_value')
    end
  end

  # PR3 (Frente C) — PRÉ-PREENCHIMENTO DA MEMÓRIA, SÓ SLOT DE FORMATO. Semeia como "proposto" o valor LEMBRADO
  # deste contato (Ai::CustomerMemory.key_facts) quando o modelo NÃO propôs, o slot perguntado é de FORMATO
  # conhecido (cpf/email/phone/number/choice) e ainda está VAZIO. Assim Ai::TurnCapture#substitute_proposed_value
  # promove na confirmação MESMO se o modelo esquecer de emitir proposed_value — a promoção é do motor, validada
  # pelo gate; não depende do modelo. O slot segue VAZIO até promover, então o caminho de AVANÇO fica intocado.
  #
  # ►► SÓ FORMATO — TEXTO LIVRE É DEFERIDO DE PROPÓSITO. ◄◄ Em texto livre um "sim" VALIDA como valor e o motor
  # gravaria "sim" no lugar do dado (família text-slot-refusal-becomes-value). A promoção de texto livre volta
  # como um JUIZ com STATUS PRÓPRIO (confirmação vs dado novo vs off-topic) — NUNCA uma lista de frases em PT,
  # que vaza e é o padrão que este projeto já aposentou uma vez.
  def seed_proposed_from_memory(attrs, step, slot)
    return '' if (attrs['ai_collected_facts'] || {})[slot].to_s.strip.present? # já preenchido: nada a propor
    return '' unless known_format_slot?(step, slot)

    remembered_fact(slot)
  end

  def known_format_slot?(step, slot)
    type = Ai::SlotCollector.new(conversation: @conversation).effective_type(step, slot)
    Ai::SlotExtractor.known_format?(type)
  end

  def remembered_fact(slot)
    return '' if @conversation.contact_id.blank?

    Ai::CustomerMemory.find_by(contact_id: @conversation.contact_id)&.key_facts.to_h[slot].to_s.strip
  end

  # O slot perguntado resolveu como AUSÊNCIA (token __sem_valor__ em ai_collected_facts)? Só a ausência
  # limpa o ponteiro; valor real fica (a confirmação-única depende dele).
  def asked_slot_absent?(attrs, key)
    Ai::StepSlot.absent?((attrs['ai_collected_facts'] || {})[key])
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

  # Gap 4 v2: turno PRODUTIVO = o cliente fez uma pergunta legítima (asks_about != 'nada', sinal do juiz) E
  # a IA respondeu (decision 'reply'). asks_about SÓ existe com o juiz ON; OFF => sempre false (conta tudo,
  # comportamento de hoje — sem regressão). Bordas aceitáveis: tool antes da resposta não é 'reply' -> conta
  # (raro em coleta); handoff/close também não, mas aí a conversa já sai. NÃO gateia por knowledge.retrieved:
  # pergunta com KB vazio emite retrieved(count 0), não skipped — o sinal certo é o asks_about, não os chunks.
  def productive_turn?(judge_result, decision)
    return false unless judge_result.is_a?(Hash)

    asks = judge_result[:asks_about].to_s
    reply = (decision.is_a?(Hash) ? decision['decision'] : nil).to_s == 'reply'
    asks.present? && asks != 'nada' && reply
  end

  # Gap 4: contador ABSOLUTO de turnos não-produtivos na etapa (ai_step_turns) — todo turno que não avança
  # (recusa, :no_attempt, confirmação-única, vazio). Substitui o antigo ai_step_stuck_turns (só-vazio),
  # dobrado no absoluto. nil no outcome => não mexe. Read-modify-write fresco, só grava quando muda.
  def persist_step_turns(count)
    return if count.nil?

    attrs = @conversation.additional_attributes || {}
    return if attrs['ai_step_turns'].to_i == count

    attrs['ai_step_turns'] = count
    @conversation.update!(additional_attributes: attrs)
  end

  # Gap 4 v2: contador SEPARADO de turnos PRODUTIVOS (ai_step_questions) — pergunta legítima respondida.
  # Teto próprio e maior (StepResolver.question_ceiling). nil => não mexe; mesmo RMW fresco do persist_step_turns.
  def persist_step_questions(count)
    return if count.nil?

    attrs = @conversation.additional_attributes || {}
    return if attrs['ai_step_questions'].to_i == count

    attrs['ai_step_questions'] = count
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
  # conversa da conta ∪ TODOS os slots DECLARADOS no playbook) e, para tipos de formato conhecido, só
  # valores que passam no Ai::SlotExtractor. Fonte :trusted devolve o hash inalterado (regressão zero).
  # Só filtra o que entra em ai_collected_facts — o espelho em custom_attributes segue igual.
  #
  # (5) allowlist ÍNDICE-INDEPENDENTE + validação ACOPLADA: o allowlist inclui todo slot declarado (não
  # só o da etapa corrente), então CORRIGIR um dado de etapa passada e ADIANTAR um de etapa futura passam
  # a ser aceitos. Mas a chave é validada pelo tipo/options do STEP QUE A DECLARA (não do slot corrente):
  # um valor fora das options de um slot choice é rejeitado mesmo com a etapa dele inativa — é o
  # acoplamento que impede a misattribution que "abrir todos os slots" abriria. LIMITE CONHECIDO E ACEITO:
  # eco DIVERGENTE de formato válido (ex.: telefone com um dígito trocado) sobrescreve o valor bom — os
  # dois são válidos, não há como distinguir; o prompt entrega o valor exato no "JÁ TENHO", então o eco
  # tende a ser idêntico e no-op. O custo do contrário é contrato errado, que é pior.
  def gated_facts(cleaned, department, source, expected_step = nil)
    @rejected_invalid = {} # (4) feedback de rejeição: chaves barradas por FORMATO neste turno (reset sempre)
    return cleaned unless source == :supervisor

    # Mapa chave -> step DECLARANTE (passo único sobre o playbook; ver #declared_slot_steps). A etapa ATIVA
    # no turno (expected_step, pré-avanço passado pelo Gateway) é a verdade mais fresca para o SEU próprio
    # slot; as demais chaves resolvem tipo/options pelo step que as declara. Chave sem step (lead/fillable)
    # segue a derivação por NOME (comportamento inalterado — ver #supervisor_fact_type).
    slot_steps = declared_slot_steps(department)
    active_key = expected_step.is_a?(Hash) ? Ai::StepSlot.attribute(expected_step).to_s : nil
    expected = supervisor_expected_keys(department, slot_steps)
    cleaned.each_with_object({}) do |(key, value), out|
      step = key.to_s == active_key ? expected_step : slot_steps[key.to_s]
      tool_dom = tool_domain(step, department)
      emit_tool_domain_unextractable(key, tool_dom) # (B2) fail-open COM telemetria (não degradar em silêncio)
      emit_inferred_type_used(key, step, expected)  # instrumentação temporária (Fase 1 do type_for_key)
      # UM único reason, COM o tool_dom — o merge do #365 duplicou esta linha e a 2ª (sem tool_dom) descartava
      # o resultado do domínio dinâmico (dead code). Recuperação: os dois lados coexistem, sem sobrescrita.
      reason = supervisor_fact_reason(key, value, expected, step, tool_dom)
      if reason
        emit('facts.rejected', { attribute: key.to_s, reason: reason })
        @rejected_invalid[key.to_s] = value if reason == 'invalid_value' # (4) só formato errado (não recusa/chave inválida)
      else
        out[key] = value
      end
    end
  end

  # (B2) DOMÍNIO DINÂMICO do slot vindo do RESULTADO da ferramenta do turno (opt-in via collect['domain_from_tool']).
  # Devolve nil quando não configurado (slot comum, gate inalterado). Quando configurado: { list: [...], tool: }
  # se der para extrair UM array de escalares do output; { list: nil, tool:, reason: } (fail-open) quando a
  # ferramenta não existe, não rodou no turno, ou o output não tem exatamente UM array de escalares.
  def tool_domain(step, department)
    tool_name = Ai::StepSlot.domain_from_tool(step)
    return nil if tool_name.blank?

    tool = department.respond_to?(:tools) ? department.tools.find_by(name: tool_name) : nil
    return { list: nil, tool: tool_name, reason: 'no_tool' } if tool.nil?

    output = latest_tool_output(tool)
    return { list: nil, tool: tool_name, reason: 'no_execution' } if output.blank?

    domain_from_output(output).merge(tool: tool_name)
  rescue StandardError => e
    Rails.logger.error "[Ai::StateManager#tool_domain] #{e.class}: #{e.message}"
    nil
  end

  def latest_tool_output(tool)
    Ai::CapabilityExecution.where(conversation_id: @conversation.id, ai_tool_id: tool.id, status: 'executed')
                           .order(created_at: :desc).first&.output
  end

  # UM array de escalares -> é o domínio; zero/múltiplos -> não adivinha (fail-open, com reason p/ telemetria).
  def domain_from_output(output)
    arrays = scalar_arrays(output).uniq
    return { list: nil, reason: arrays.empty? ? 'none' : 'ambiguous' } unless arrays.size == 1

    { list: arrays.first.map { |v| v.to_s.strip }.reject(&:blank?) }
  end

  def out_of_tool_domain?(value, tool_dom)
    tool_dom && tool_dom[:list] && !in_tool_domain?(value, tool_dom[:list])
  end

  def emit_tool_domain_unextractable(key, tool_dom)
    return unless tool_dom && tool_dom[:list].nil?

    emit('tool_domain.unextractable', { attribute: key.to_s, tool: tool_dom[:tool], reason: tool_dom[:reason] })
  end

  # Acha, RECURSIVAMENTE e em QUALQUER profundidade, arrays cujos elementos são TODOS escalares (string/número)
  # — genérico, sem assumir a forma do webhook ({body:{periodos}}, {data:{slots}}, {available:[]}, lista crua).
  def scalar_arrays(node)
    case node
    when Array
      inner = node.flat_map { |v| scalar_arrays(v) }
      scalar_array?(node) ? [node] + inner : inner
    when Hash
      node.values.flat_map { |v| scalar_arrays(v) }
    else
      []
    end
  end

  def scalar_array?(arr)
    arr.any? && arr.all? { |e| e.is_a?(String) || e.is_a?(Numeric) }
  end

  def in_tool_domain?(value, list)
    v = value.to_s.strip
    list.any? { |d| d.casecmp?(v) }
  end

  # INSTRUMENTAÇÃO TEMPORÁRIA (Fase 1 do type_for_key) — mede o RESIDUAL step-less antes de apagar a
  # inferência de tipo por vocabulário PT/BR. Emite quando o gate resolveria o tipo de um fato ESPERADO pela
  # INFERÊNCIA (type_for_key), não por `type` declarado — ou seja, o caso que PERDE validação na Fase 2. Slots
  # de etapa já declaram o tipo (query em prod = 0); isto pega lead_variable/fillable (step nil) e qualquer step
  # com `type` 'text'. REMOVER junto com type_for_key na Fase 2. Recomputa type_for_key (barato); não altera o gate.
  def emit_inferred_type_used(key, step, expected)
    return unless expected.include?(key.to_s)            # só o que seria de fato validado
    return if step && Ai::StepSlot.type(step) != 'text'  # tipo DECLARADO -> não é inferência

    inferred = Ai::SlotExtractor.type_for_key(key)
    return if inferred.blank?                             # a chave não infere formato -> nada a medir

    emit('slot.inferred_type_used', { attribute: key.to_s, inferred_type: inferred, step_less: step.nil? })
  end

  # (item 5) O valor CRU do slot da etapa CORRENTE passaria no gate? MESMO veredito do gated_facts
  # (supervisor_fact_reason), calculado ANTES do gate rodar de fato — o Gateway persiste :supervisor DEPOIS
  # do track_step (gateway.rb:204), então o avanço não pode reler "o persistido" para o valor NOVO. Para o
  # slot corrente, o step DECLARANTE é a própria etapa corrente (o `active_key` do gated_facts), então
  # passamos `step` direto — mesmas resoluções (declared_slot_steps/supervisor_expected_keys), mesmo
  # julgamento. false quando não há valor cru OU ele seria rejeitado (unexpected/declined/invalid): aí o slot
  # só conta como preenchido se JÁ persistido (ver Ai::StepResolver#slot_filled?). Consumido pelo resolver.
  def supervisor_slot_valid?(department, step, decision)
    slot = Ai::StepSlot.attribute(step)
    return false if slot.blank?

    value = decision['attributes'].is_a?(Hash) ? decision['attributes'][slot] : nil
    return false if value.to_s.strip.blank?

    expected = supervisor_expected_keys(department, declared_slot_steps(department))
    supervisor_fact_reason(slot, value, expected, step, tool_domain(step, department)).nil?
  rescue StandardError => e
    Rails.logger.error "[Ai::StateManager#supervisor_slot_valid?] #{e.class}: #{e.message}"
    false
  end

  # Mapa {chave_declarada => step} de TODOS os slots do playbook (declarado ∪ inferido, via
  # StepSlot.attribute). Passo ÚNICO sobre steps — a mesma varredura que alimenta o allowlist
  # (supervisor_expected_keys lê slot_steps.keys). COLISÃO (duas etapas declarando a MESMA chave):
  # "primeira que declara vence" + emite slot.duplicate_declaration e loga — é erro de CONFIGURAÇÃO do
  # playbook (a 2ª etapa nunca gravaria seu slot); o dono precisa ver, não descobrir por comportamento
  # estranho. Chave nil (etapa informativa) não entra.
  def declared_slot_steps(department)
    Array(department&.playbook&.steps).each_with_object({}) do |step, map|
      key = Ai::StepSlot.attribute(step).to_s
      next if key.blank?

      if map.key?(key)
        emit('slot.duplicate_declaration',
             { attribute: key, kept_step: step_name(map[key]), ignored_step: step_name(step) })
        Rails.logger.warn "[Ai::StateManager] slot #{key.inspect} declarado em duas etapas " \
                          "(#{step_name(map[key]).inspect} e #{step_name(step).inspect}); a 1ª vence"
        next
      end
      map[key] = step
    end
  end

  # Conjunto de chaves que o supervisor PODE gravar como fato: atributos de conversa da conta (mesma
  # resolução do filter_known_attributes) + lead_variables do department + TODOS os slots declarados no
  # playbook (slot_steps.keys). ÍNDICE-INDEPENDENTE de propósito (ver gated_facts): passou a etapa, o slot
  # continua gravável — é o que destrava a correção retroativa e o dado adiantado. Chave fora dos três
  # conjuntos continua unexpected_key (proteção anti-alucinação intacta).
  def supervisor_expected_keys(department, slot_steps)
    fillable_attribute_keys(department) + lead_variable_keys(department) + slot_steps.keys
  end

  # Nomes das lead_variables do department (a CHAVE que o prompt pede no campo `attributes`). [] em erro.
  def lead_variable_keys(department)
    return [] unless department.respond_to?(:lead_variables)

    department.lead_variables.to_a.map { |v| v.name.to_s }
  rescue StandardError => e
    Rails.logger.error "[Ai::StateManager#lead_variable_keys] #{e.class}: #{e.message}"
    []
  end

  # Motivo de rejeição de um fato do supervisor, ou nil (aceito). 'unexpected_key' = chave fora do
  # conjunto esperado; 'invalid_value' = tipo de formato conhecido cujo valor não passa no extractor.
  # `step` = a etapa que DECLARA esta chave (nil p/ lead_variable/fillable, que não têm step). Chave
  # esperada de tipo livre (text/derivável nil) é aceita (não há formato para validar).
  def supervisor_fact_reason(key, value, expected, step, tool_dom = nil)
    return 'unexpected_key' unless expected.include?(key.to_s)
    # Gap 1: valor de recusa/ausência do modelo (token ou expressão) NÃO vira fato — antes da validação de
    # formato, para pegar também slot de TEXTO (fecha o nome_cliente="não informado" aberto pelo gate fix).
    # A sentinela em ai_collected_facts vem só do caminho fill_absent (slot opcional), com o token canônico.
    return 'declined' if Ai::SlotAbsence.absence_value?(value)
    # (B2) Domínio DINÂMICO da ferramenta: se a etapa declara domain_from_tool e o resultado do turno é um
    # domínio EXTRAÍVEL, o valor tem de estar nele — vale para modelo E juiz (ambos via :supervisor). Domínio
    # não-extraível (tool_dom[:list] nil) => fail-open (não rejeita; a telemetria sai no gated_facts).
    return 'not_in_tool_result' if out_of_tool_domain?(value, tool_dom)

    type = supervisor_fact_type(key, step)
    return nil unless Ai::SlotExtractor.known_format?(type)

    # ACOPLAMENTO (5): tipo E options vêm do STEP DECLARANTE, não do slot corrente — um valor fora das
    # options de um slot choice é rejeitado mesmo com a etapa dele inativa (prova do acoplamento). Sem step
    # (lead/fillable) não há options declaradas.
    options = step ? Ai::StepSlot.options(step) : []
    Ai::SlotExtractor.extract(attribute_type: type, text: value.to_s, options: options).blank? ? 'invalid_value' : nil
  end

  # Tipo do fato: se a chave é slot de um step, usa o effective_type DAQUELE step (collect.type ou derivado
  # da chave); lead_variable/fillable (step nil) derivam só do NOME via type_for_key. nil/'text' => tipo
  # livre (sem validação de formato).
  def supervisor_fact_type(key, step)
    if step
      Ai::SlotCollector.new(conversation: @conversation).effective_type(step, key)
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
