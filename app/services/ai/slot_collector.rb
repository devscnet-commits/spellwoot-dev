# Captura e validação leve de um slot de etapa (conserto). DECIDE o dado que o cliente forneceu
# (SlotExtractor por tipo OU texto cru — sempre gravável, Parte 2) SEM persistir (quem grava é o
# StateManager, via persist_attributes, que já espelha para custom_attributes); decide se precisa
# confirmar UMA vez (valor estranho para o tipo derivado da chave, Parte 3) e gerencia o flag de
# confirmação por etapa. Extraído do StateManager (que já concentrava persist #256 + steps #259 +
# captura) para não crescer sem limite.
class Ai::SlotCollector
  def initialize(conversation:)
    @conversation = conversation
  end

  # Slot preenchido? Valor devolvido pelo modelo NESTE turno (decision, ainda não persistido) OU já
  # gravado em ai_collected_facts. Preserva false/0 como preenchidos.
  def filled?(slot, decision)
    pending = decision['attributes']
    return true if pending.is_a?(Hash) && pending[slot].to_s.strip.present?

    persisted?(slot)
  end

  # Metade PERSISTIDA do filled? (item 5): valor JÁ gravado em ai_collected_facts — captura determinística
  # DESTA rodada (turn_capture roda ANTES do resolve), turno anterior ou confirmação. Extraída para o
  # StepResolver decidir o AVANÇO pelo estado + veredito do gate, sem contar o cru do modelo pré-gate.
  # present? (inclui a sentinela) — semântica idêntica à metade persistida do filled? de antes.
  def persisted?(slot)
    facts = collected_facts
    facts.is_a?(Hash) && facts[slot].to_s.strip.present?
  end

  # DECIDE o dado do cliente para o slot (não persiste): tenta o SlotExtractor (tipo conhecido); se não
  # extrair, usa o TEXTO CRU (genérico). Só quando o slot está vazio (não sobrescreve valor já presente
  # — evita gravar "já mandei" por cima). Retorna { value:, source: 'extractor'|'raw' } ou nil (nada a
  # capturar). Quem GRAVA é o StateManager (via persist_attributes, que também espelha para
  # custom_attributes quando a chave tem campo cadastrado) — assim a captura reaproveita o mesmo
  # caminho de persistência/espelhamento do modelo, sem duplicar a regra.
  def capture_value(step, slot, decision, message_text)
    return if filled?(slot, decision)
    return if message_text.to_s.strip.empty?

    type = effective_type(step, slot)
    options = Ai::StepSlot.options(step)
    extracted = Ai::SlotExtractor.extract(attribute_type: type, text: message_text, options: options)
    return { value: extracted, source: 'extractor' } if extracted.present?

    # (B) Slot de tipo com FORMATO conhecido em que o cliente NÃO tentou responder (ex.: fez uma
    # pergunta): NÃO grava o cru — devolve :no_attempt para o caller recusar e observar (slot.no_attempt).
    # Slot 'text' (sem formato derivável): comportamento INALTERADO — grava o texto cru.
    return { no_attempt: true, type: type } if no_attempt?(type, message_text, options)

    { value: message_text.to_s.strip, source: 'raw' }
  rescue StandardError => e
    Rails.logger.error "[Ai::SlotCollector#capture_value] #{e.class}: #{e.message}"
    nil
  end

  # (A) Tipo EFETIVO do slot: o declarado em `collect` vence; se for 'text', tenta derivar do NOME da
  # chave (email/cpf/telefone via SlotExtractor.type_for_key). Chave sem tipo derivável continua 'text'.
  def effective_type(step, slot)
    declared = Ai::StepSlot.type(step)
    return declared unless declared == 'text'

    Ai::SlotExtractor.type_for_key(slot) || 'text'
  end

  # Tipo com formato conhecido E o cliente não fez tentativa de resposta neste turno.
  def no_attempt?(type, message_text, options)
    Ai::SlotExtractor.known_format?(type) &&
      !Ai::SlotExtractor.attempt?(attribute_type: type, text: message_text, options: options)
  end

  # Parte 3: deve pedir confirmação UMA vez? true quando o valor parece estranho (formato) E ainda não
  # confirmamos nesta etapa. Marca o flag (efeito colateral) para não confirmar de novo. Chave genérica
  # nunca é "estranha" (SlotExtractor.malformed? => false) -> grava e segue direto.
  def needs_confirmation?(slot, decision, index)
    return false unless Ai::SlotExtractor.malformed?(slot, current_value(slot, decision))
    return false if confirmed_index == index

    mark_confirmed(index)
    true
  end

  private

  def current_value(slot, decision)
    pending = decision['attributes']
    return pending[slot] if pending.is_a?(Hash) && pending[slot].to_s.strip.present?

    (collected_facts || {})[slot]
  end

  def collected_facts
    (@conversation.additional_attributes || {})['ai_collected_facts']
  end

  def confirmed_index
    (@conversation.additional_attributes || {})['ai_step_confirm_index']
  end

  def mark_confirmed(index)
    attrs = @conversation.additional_attributes || {}
    attrs['ai_step_confirm_index'] = index
    @conversation.update!(additional_attributes: attrs)
  end
end
