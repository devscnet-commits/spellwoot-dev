# Decisão de CONCLUSÃO da etapa (pura — não persiste). Extraída do Ai::StateManager (God object) junto
# com o Ai::TurnCapture/#265. Decide, a partir do estado + do sinal da captura do turno, se a etapa
# avança, segura para confirmação-única, ou aciona uma das DUAS redes de handoff.
#
# Duas redes (Gap 4):
#  - RECUSA (mais cedo): declínio/juiz not_an_answer -> ai_slot_refusals, teto DERIVADO e MENOR que o
#    absoluto, reason próprio ('declined'/'not_an_answer'/...). Transfere o recusador antes.
#  - ABSOLUTO (última rede): TODO turno não-produtivo na etapa (recusa + :no_attempt + confirmação-única +
#    vazio) -> ai_step_turns, teto = stuck_handoff_turns (o campo da tela). reason 'max_turns'. É a rede
#    que pega o cliente que só faz perguntas (:no_attempt não tinha contador). O antigo ai_step_stuck_turns
#    (só-vazio) foi DOBRADO aqui.
#
# Retorna sempre um Hash-outcome: { completed:, turns: (opcional/nil = não mexe), refusals: (idem),
# confirm: (opcional), signal: (opcional stuck_handoff) }. Quem GRAVA os contadores/índice é o
# StateManager (persist_progress). Opera sobre a MESMA conversa (o slot_collector.mark_confirmed e as
# leituras dos contadores usam @conversation, sincronizado pelo StateManager).
class Ai::StepResolver
  def initialize(conversation:)
    @conversation = conversation
  end

  # capture_signal: nil (capturou/nada), :no_attempt (#269, slot de tipo conhecido sem tentativa),
  # { refusal: ... } (juiz recusou) ou { declined: true } (Gap 1, cliente declinou o dado).
  def resolve_completion(step, decision, stuck_limit, index, capture_signal)
    # Gap 2: attribute (declarado ∪ INFERIDO) governa "há slot?" E a captura.
    slot = Ai::StepSlot.attribute(step)
    return { completed: step_completed?(decision), turns: 0, refusals: 0 } unless slot

    # INVARIANTE (Gaps 3/4): ao SAIR de um slot obrigatório, ou os contadores foram ZERADOS (só no avanço
    # genuíno: completed:true), ou houve stuck_handoff (outcome[:signal]). NÃO existe caminho que avance um
    # slot obrigatório com contador cheio — por isso NÃO há reset por mudança de etapa (reabriria a
    # alternância). A rede de RECUSA é avaliada em resolve_slot; o teto ABSOLUTO é a rede de FORA
    # (apply_absolute_ceiling), que roda DEPOIS e NUNCA sobrescreve um handoff por recusa devido (Q5).
    outcome = resolve_slot(step, slot, decision, index, stuck_limit, capture_signal)
    apply_absolute_ceiling(step, slot, stuck_limit, outcome)
  end

  private

  def resolve_slot(step, slot, decision, index, stuck_limit, capture_signal)
    return resolve_declined(step, slot, stuck_limit) if capture_signal.is_a?(Hash) && capture_signal[:declined]
    return resolve_filled_slot(slot, decision, index) if slot_filled?(slot, decision)

    resolve_empty_slot(step, slot, stuck_limit, capture_signal)
  end

  # TETO ABSOLUTO (Gap 4) — a ÚLTIMA rede. Conta TODO turno não-produtivo na etapa (recusa, :no_attempt,
  # confirmação-única, vazio) em ai_step_turns; ao atingir stuck_limit, transfere (reason 'max_turns').
  # Roda DEPOIS da rede de recusa: se ela já emitiu signal neste turno, RESPEITA (não pré-empta — Q5).
  # Reset no AVANÇO. Carrega refusals junto quando dispara com recusas > 0 (telemetria da ALTERNÂNCIA:
  # em recusa/pergunta/recusa o absoluto sobe todo turno e a recusa só nas recusas, então o max_turns pode
  # disparar antes do teto de recusa — o campo refusals preserva quantas recusas houve).
  def apply_absolute_ceiling(step, slot, stuck_limit, outcome)
    return outcome.merge(turns: 0) if outcome[:completed] # avançou -> zera o absoluto
    return outcome if outcome[:signal]                    # recusa JÁ transferiu neste turno -> respeita

    turns = current_turns + 1
    return outcome.merge(turns: turns) unless stuck_limit.positive? && turns >= stuck_limit

    # refusals p/ a telemetria: o valor FRESCO deste turno (outcome[:refusals], ainda não persistido) quando
    # a rede de recusa mexeu; senão o valor persistido. Sem isso, o max_turns registraria uma recusa a menos.
    refusals = outcome.key?(:refusals) ? outcome[:refusals].to_i : current_refusals
    outcome.merge(turns: 0, signal: stuck_handoff_signal(step, slot, turns, 'max_turns', refusals))
  end

  # Cliente declinou o dado. OPCIONAL -> satisfaz com a sentinela de ausência (fill_absent) e AVANÇA;
  # zera o orçamento (foi resolvido). OBRIGATÓRIO -> conta como recusa (rede de recusa, reason 'declined').
  def resolve_declined(step, slot, stuck_limit)
    return { completed: true, refusals: 0, fill_absent: slot } if Ai::StepSlot.optional?(step)

    resolve_judge_refusal(step, slot, stuck_limit, 'declined')
  end

  # Só é alcançado para etapa SEM slot (attribute nil): segue o sinal do modelo.
  def step_completed?(decision)
    truthy?(decision['step_completed'])
  end

  def slot_collector
    @slot_collector ||= Ai::SlotCollector.new(conversation: @conversation)
  end

  def slot_filled?(slot, decision)
    slot_collector.filled?(slot, decision)
  end

  # Slot VAZIO. Recusa do juiz -> rede de RECUSA (resolve_judge_refusal). :no_attempt e vazio -> sem
  # contador PRÓPRIO: o teto ABSOLUTO (apply_absolute_ceiling, de fora) conta e transfere. (O antigo
  # ai_step_stuck_turns, contador só-de-vazio, foi dobrado no absoluto — uma rede a menos.)
  def resolve_empty_slot(step, slot, stuck_limit, capture_signal)
    refusal = capture_signal.is_a?(Hash) ? capture_signal[:refusal] : nil
    return resolve_judge_refusal(step, slot, stuck_limit, refusal) if refusal

    { completed: false }
  end

  # Rede de RECUSA (declínio / juiz not_an_answer / judge_failed). Teto DERIVADO e MENOR que o absoluto,
  # para o recusador transferir ANTES e com reason próprio (Q5). Gap 3: só o avanço zera; a confirmação-única
  # SEGURA (não zera). Ao atingir o teto, sinaliza; senão acumula.
  def resolve_judge_refusal(step, slot, stuck_limit, refusal)
    refusals = current_refusals + 1
    ceiling = refusal_ceiling(stuck_limit)
    if ceiling.positive? && refusals >= ceiling
      return { completed: false, refusals: 0, signal: stuck_handoff_signal(step, slot, refusals, refusal) }
    end

    { completed: false, refusals: refusals }
  end

  # Teto de RECUSA: metade do absoluto (mínimo 2), clampado a <= absoluto — garante que a recusa nunca
  # exija MAIS turnos que o absoluto (senão o absoluto pré-emptaria, matando a rede de recusa). 0 quando o
  # absoluto está desligado (stuck_limit 0 = rede off).
  def refusal_ceiling(stuck_limit)
    return 0 unless stuck_limit.positive?

    [[stuck_limit / 2, 2].max, stuck_limit].min
  end

  # Sinal de handoff (Camada B). reason distingue a rede: 'declined'/'not_an_answer'/'judge_failed'/
  # 'attachment_no_slot' (recusa) e 'max_turns' (absoluto). refusals: N acompanha SÓ o 'max_turns' quando
  # houve recusas — preserva a telemetria de "quais etapas travam mais" na alternância (senão o max_turns
  # esconderia que houve recusas no meio).
  def stuck_handoff_signal(step, slot, turns, reason = nil, refusals = nil)
    payload = { attribute: slot, step_name: (step_name(step).presence || slot), turns: turns }
    payload[:reason] = reason if reason
    payload[:refusals] = refusals.to_i if reason == 'max_turns' && refusals.to_i.positive?
    { stuck_handoff: payload }
  end

  # Slot já preenchido: confirmação-única (valor malformado) ou AVANÇA. Gap 3: SÓ o avanço zera as recusas;
  # a confirmação-única SEGURA (o teto absoluto de fora conta este turno como não-produtivo).
  def resolve_filled_slot(slot, decision, index)
    return { completed: true, refusals: 0 } unless slot_collector.needs_confirmation?(slot, decision, index)

    { completed: false, confirm: true, refusals: current_refusals }
  end

  def current_turns
    (@conversation.additional_attributes || {})['ai_step_turns'].to_i
  end

  def current_refusals
    (@conversation.additional_attributes || {})['ai_slot_refusals'].to_i
  end

  def step_name(step)
    return '' unless step.is_a?(Hash)

    (step['name'] || step[:name]).to_s.strip
  end

  def truthy?(value)
    value == true || value.to_s.strip.casecmp?('true')
  end
end
