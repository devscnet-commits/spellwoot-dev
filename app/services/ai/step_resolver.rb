# Decisão de CONCLUSÃO da etapa (pura — não persiste). Extraída do Ai::StateManager (God object) junto
# com o Ai::TurnCapture/#265. Decide, a partir do estado + do sinal da captura do turno, se a etapa
# avança, segura para confirmação-única, conta travamento (#259) ou aciona a rede de recusas do juiz.
#
# Retorna sempre um Hash-outcome: { completed:, stuck:, refusals: (opcional/nil = não mexe),
# confirm: (opcional), signal: (opcional stuck_handoff) }. Quem GRAVA os contadores/índice é o
# StateManager (persist_progress). Opera sobre a MESMA conversa (o slot_collector.mark_confirmed e as
# leituras dos contadores usam @conversation, sincronizado pelo StateManager).
class Ai::StepResolver
  def initialize(conversation:)
    @conversation = conversation
  end

  # capture_signal: nil (capturou/nada ou cliente sumido), :no_attempt (#269, slot de tipo conhecido sem
  # tentativa) ou { refusal: 'not_an_answer'|'judge_failed' } (worker de julgamento recusou o turno).
  #  - etapa SEM slot (informativa/antiga): step_completed do modelo.
  #  - slot PREENCHIDO: confirmação-única (Parte 3) ou AVANÇA.
  #  - slot VAZIO: ver resolve_empty_slot.
  def resolve_completion(step, decision, stuck_limit, index, capture_signal)
    # Gap 1: recusa/ausência do dado (detectada no Ai::TurnCapture). Roteada ANTES do slot_filled? porque
    # o valor de recusa que o modelo devolve (ex.: "não informado") faria slot_filled? passar e cair na
    # confirmação-única. Ortogonal ao tipo do slot; o que muda é a resposta (ver resolve_declined).
    declined = capture_signal.is_a?(Hash) && capture_signal[:declined]
    slot_any = Ai::StepSlot.attribute(step)
    return resolve_declined(step, slot_any, stuck_limit) if declined && slot_any

    slot = Ai::StepSlot.required_attribute(step)
    return { completed: step_completed?(step, decision), stuck: 0, refusals: 0 } unless slot
    return resolve_filled_slot(slot, decision, index) if slot_filled?(slot, decision)

    resolve_empty_slot(step, slot, stuck_limit, capture_signal)
  end

  private

  # Cliente declinou o dado. OPCIONAL -> satisfaz com a sentinela de ausência (fill_absent) e AVANÇA;
  # zera o orçamento (foi resolvido). OBRIGATÓRIO -> NÃO preenche; conta como recusa (contador próprio,
  # reason 'declined' distingue do travamento no resumo do handoff) e, no teto, TRANSFERE. Reusa o mesmo
  # resolve_judge_refusal do #270 (teto = stuck_limit*2).
  def resolve_declined(step, slot, stuck_limit)
    return { completed: true, stuck: 0, refusals: 0, fill_absent: slot } if Ai::StepSlot.optional?(step)

    resolve_judge_refusal(step, slot, stuck_limit, 'declined')
  end

  # Conclusão determinística: 'always' e etapas sem slot seguem o step_completed do modelo; etapa com
  # slot obrigatório conclui quando o slot está preenchido (valor do turno OU já gravado).
  def step_completed?(step, decision)
    return truthy?(decision['step_completed']) if Ai::StepSlot.criterion(step) == 'always'

    slot = Ai::StepSlot.required_attribute(step)
    return slot_filled?(slot, decision) if slot

    truthy?(decision['step_completed'])
  end

  def slot_collector
    @slot_collector ||= Ai::SlotCollector.new(conversation: @conversation)
  end

  def slot_filled?(slot, decision)
    slot_collector.filled?(slot, decision)
  end

  # Slot VAZIO. capture_signal decide:
  #  - { refusal: ... } (juiz recusou) -> contador SEPARADO de recusas consecutivas (não o normal), teto
  #    próprio -> resolve_judge_refusal.
  #  - :no_attempt (#269, cliente engajado num slot de tipo conhecido) -> NÃO conta nada (mantém ambos).
  #  - nil (cliente sumido, message_text vazio, #259) -> conta o contador NORMAL; ao atingir o limite
  #    (>0), sinaliza HANDOFF.
  def resolve_empty_slot(step, slot, stuck_limit, capture_signal)
    refusal = capture_signal.is_a?(Hash) ? capture_signal[:refusal] : nil
    return resolve_judge_refusal(step, slot, stuck_limit, refusal) if refusal
    return { completed: false, stuck: current_stuck } if capture_signal == :no_attempt

    stuck = current_stuck + 1
    return { completed: false, stuck: stuck } unless stuck_limit.positive? && stuck >= stuck_limit

    { completed: false, stuck: 0, signal: stuck_handoff_signal(step, slot, stuck) }
  end

  # AJUSTE 1 — teto para recusas CONSECUTIVAS do juiz (not_an_answer / judge_failed). Contador próprio
  # (ai_slot_refusals), sem tocar o contador normal (o cliente que faz perguntas NÃO é punido). Teto =
  # 2 × stuck_handoff_turns; 0 desliga a rede (teto também desligado). Ao atingir o teto, reusa o MESMO
  # step.stuck_handoff (aviso + transferência + resumo) com o motivo no payload; senão só acumula.
  def resolve_judge_refusal(step, slot, stuck_limit, refusal)
    refusals = current_refusals + 1
    ceiling = stuck_limit.positive? ? stuck_limit * 2 : 0
    if ceiling.positive? && refusals >= ceiling
      return { completed: false, stuck: current_stuck, refusals: 0,
               signal: stuck_handoff_signal(step, slot, refusals, refusal) }
    end

    { completed: false, stuck: current_stuck, refusals: refusals }
  end

  # Sinal de handoff por travamento (Camada B). reason presente só na recusa do juiz — o handoff do #259
  # (cliente sumido) mantém a forma { attribute, step_name, turns } sem reason (compat).
  def stuck_handoff_signal(step, slot, turns, reason = nil)
    payload = { attribute: slot, step_name: (step_name(step).presence || slot), turns: turns }
    payload[:reason] = reason if reason
    { stuck_handoff: payload }
  end

  # Slot já preenchido: se o valor parece estranho e ainda não confirmamos, pede confirmação UMA vez
  # (hold); senão AVANÇA. O hold NÃO conta travamento — malformado É coleta (grava e avança pela
  # confirmação-única, decisão #2); o contador de trava é só para etapa que NÃO coleta (decisão #3). Em
  # ambos o slot foi capturado -> ZERA as recusas.
  def resolve_filled_slot(slot, decision, index)
    return { completed: true, stuck: 0, refusals: 0 } unless slot_collector.needs_confirmation?(slot, decision, index)

    { completed: false, stuck: current_stuck, confirm: true, refusals: 0 }
  end

  def current_stuck
    (@conversation.additional_attributes || {})['ai_step_stuck_turns'].to_i
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
