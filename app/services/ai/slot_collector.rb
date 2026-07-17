# Captura e validação leve de um slot de etapa (conserto). Grava o dado que o cliente forneceu
# (SlotExtractor por tipo OU texto cru — sempre gravável, Parte 2), decide se precisa confirmar UMA vez
# (valor estranho para o tipo derivado da chave, Parte 3) e gerencia o flag de confirmação por etapa.
# Opera sobre a conversa (ai_collected_facts + ai_step_confirm_index em additional_attributes), com a
# mesma disciplina read-modify-write do Ai::StateManager. Extraído do StateManager (que já concentrava
# persist #256 + steps #259 + captura) para não crescer sem limite.
class Ai::SlotCollector
  def initialize(conversation:)
    @conversation = conversation
  end

  # Slot preenchido? Valor devolvido pelo modelo NESTE turno (decision, ainda não persistido) OU já
  # gravado em ai_collected_facts. Preserva false/0 como preenchidos.
  def filled?(slot, decision)
    pending = decision['attributes']
    return true if pending.is_a?(Hash) && pending[slot].to_s.strip.present?

    facts = collected_facts
    facts.is_a?(Hash) && facts[slot].to_s.strip.present?
  end

  # Grava o dado do cliente se o slot ainda está vazio e há mensagem: tenta o SlotExtractor (tipo
  # conhecido); se não extrair, grava o TEXTO CRU (genérico). Não sobrescreve valor já presente (evita
  # gravar "já mandei" por cima). Retorna 'extractor' | 'raw' | nil (nada capturado).
  def capture(step, slot, decision, message_text)
    return if filled?(slot, decision)
    return if message_text.to_s.strip.empty?

    extracted = Ai::SlotExtractor.extract(attribute_type: Ai::StepSlot.type(step), text: message_text,
                                          options: Ai::StepSlot.options(step))
    write_fact(slot, extracted.presence || message_text.to_s.strip)
    extracted ? 'extractor' : 'raw'
  rescue StandardError => e
    Rails.logger.error "[Ai::SlotCollector#capture] #{e.class}: #{e.message}"
    nil
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

  def write_fact(slot, value)
    attrs = @conversation.additional_attributes || {}
    facts = (attrs['ai_collected_facts'] || {}).merge(slot => value)
    return if facts == attrs['ai_collected_facts']

    attrs['ai_collected_facts'] = facts
    @conversation.update!(additional_attributes: attrs)
  end

  def mark_confirmed(index)
    attrs = @conversation.additional_attributes || {}
    attrs['ai_step_confirm_index'] = index
    @conversation.update!(additional_attributes: attrs)
  end
end
