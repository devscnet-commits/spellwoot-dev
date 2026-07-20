# Captura de UM turno para o slot da etapa corrente (BUG 1 + BUG 3). Extraído do Ai::StateManager (já
# sobrecarregado com persist #256 + steps #259 + conserto) para concentrar a responsabilidade.
#
# BUG 1 (idempotência): #claim garante que a MESMA mensagem preenche NO MÁXIMO UM slot — em memória
# (mesmo run/objeto) e via UPDATE condicional atômico no Postgres (runs/bindings concorrentes). Só o 1º
# run processa; re-run/binding/re-enfileiramento é no-op (não re-captura nem re-avança).
# Opção B (precedência do modelo): #capture só grava TEXTO CRU quando o modelo não devolveu attributes.
# Se o modelo devolveu attributes mas nenhuma chave bate com o slot corrente => mismatch (evento, sem cru).
# BUG 3 (anexo vira estado): anexo grava fatos determinísticos e, se for a resposta da etapa, preenche o slot.
#
# Persiste pelo `persister` (o Ai::StateManager) -> reaproveita persist_attributes e herda o espelhamento
# para custom_attributes (#265). Opera sobre a MESMA conversa do StateManager (a sincronização em memória
# do claim preserva os RMW seguintes de persist_step_state).
class Ai::TurnCapture
  def initialize(conversation:, persister:)
    @conversation = conversation
    @persister = persister
    @claimed = []
  end

  # true = ESTE run ganhou a mensagem (deve capturar/avançar). false = já processada (no-op). Sem
  # message_id (follow-up/teste) => true (sem idempotência). Fail-open em erro (melhor capturar que travar).
  def claim(message)
    id = message.respond_to?(:id) ? message.id : nil
    return true if id.blank?
    return false if @claimed.include?(id)

    won = atomic_claim(id)
    @claimed << id if won
    won
  end

  # Captura o dado desta mensagem para o slot corrente (anexo -> modelo -> texto cru). department é
  # necessário para o espelhamento em custom_attributes.
  def capture(step, decision, message_text, message, department)
    slot = Ai::StepSlot.required_attribute(step)
    # BUG 3 antes do guard de slot: o anexo vira FATO determinístico mesmo em etapa sem slot (localização
    # numa etapa informativa). Se a etapa coleta E o anexo é a resposta, também preenche o slot.
    return if capture_attachment(message, slot, department)
    return unless slot

    attrs = decision['attributes'].is_a?(Hash) ? reject_blank(decision['attributes']) : {}
    if attrs.empty?
      return capture_from_text(step, slot, decision, message_text, department)
    elsif !attrs.key?(slot)
      emit('slot.model_key_mismatch', { expected: slot, got: attrs.keys })
    end
    nil
  end

  # Modelo MUDO (sem attributes): captura pelo texto do cliente (extractor OU cru, via SlotCollector).
  # Recusa o cru quando o slot tem tipo conhecido e não houve tentativa -> devolve :no_attempt (o
  # StateManager não conta travamento nesse turno). Caso contrário devolve nil.
  def capture_from_text(step, slot, decision, message_text, department)
    cap = Ai::SlotCollector.new(conversation: @conversation).capture_value(step, slot, decision, message_text)
    return unless cap
    return refuse_no_attempt(slot, cap[:type]) if cap[:no_attempt]

    @persister.persist_attributes({ slot => cap[:value] }, department)
    emit('slot.captured', { attribute: slot, source: cap[:source] })
    nil
  end

  private

  # UPDATE conversations SET ...ai_last_captured_message_id = <id> WHERE id = ? AND (atual IS DISTINCT
  # FROM <id>). Só 1 run afeta a linha (checagem de linhas afetadas); quem perde afeta 0 e não captura.
  # Sincroniza a marca em memória para os RMW seguintes (persist_step_state) não a clobbarem.
  def atomic_claim(id)
    quoted = ::ActiveRecord::Base.connection.quote(id.to_s)
    set_sql = "additional_attributes = jsonb_set(coalesce(additional_attributes, '{}'::jsonb), " \
              "'{ai_last_captured_message_id}', to_jsonb(#{quoted}::text))"
    cond_sql = "(additional_attributes->>'ai_last_captured_message_id') IS DISTINCT FROM #{quoted}"
    # rubocop:disable Rails/SkipsModelValidations
    won = ::Conversation.where(id: @conversation.id).where(cond_sql).update_all(::Arel.sql(set_sql)).positive?
    # rubocop:enable Rails/SkipsModelValidations
    if won
      attrs = @conversation.additional_attributes || {}
      @conversation.assign_attributes(additional_attributes: attrs.merge('ai_last_captured_message_id' => id.to_s))
    end
    won
  rescue StandardError => e
    Rails.logger.error "[Ai::TurnCapture#atomic_claim] #{e.class}: #{e.message}"
    true
  end

  # BUG 3: grava fatos determinísticos do anexo (via persist_attributes -> espelhamento) e preenche o
  # slot corrente se o anexo é a resposta da etapa. true quando havia anexo (é a captura desta mensagem).
  def capture_attachment(message, slot, department)
    facts, kind, slot_value = attachment_facts(message)
    return false unless facts

    @persister.persist_attributes(facts, department)
    @persister.persist_attributes({ slot => slot_value }, department) if slot && slot_value
    emit('attachment.captured', { kind: kind, attribute: (slot && slot_value ? slot : nil) })
    true
  end

  # [facts, kind, slot_value] do anexo (metadados — sem depender do MediaProcessor), ou [nil, nil, nil].
  # Localização só grava fatos; documento/imagem preenchem o slot corrente com o nome do arquivo.
  def attachment_facts(message)
    att = Array(message.try(:attachments)).find { |a| %w[location file image].include?(a.file_type.to_s) }
    return [nil, nil, nil] unless att

    if att.file_type.to_s == 'location'
      facts = { 'localizacao_recebida' => true,
                'localizacao_coordenadas' => "#{att.coordinates_lat},#{att.coordinates_long}" }
      facts['localizacao_link'] = att.external_url if att.external_url.present?
      [facts, 'location', nil]
    else
      name = attachment_name(att)
      [{ 'documento_recebido' => true, 'documento_arquivo' => name }, att.file_type.to_s, name]
    end
  end

  def attachment_name(att)
    (att.file.attached? ? att.file.blob.filename.to_s : att.fallback_title.to_s).presence || 'anexo'
  end

  def reject_blank(attrs)
    attrs.reject { |_k, v| v.to_s.strip.empty? }
  end

  # (D) O cru foi RECUSADO por não ser tentativa de resposta (slot de tipo conhecido). Observabilidade +
  # sinal (:no_attempt) para o StateManager NÃO contar travamento neste turno. Não persiste nada.
  def refuse_no_attempt(slot, type)
    emit('slot.no_attempt', { attribute: slot, type: type })
    :no_attempt
  end

  def emit(type, payload)
    Ai::Event.create!(account_id: @conversation.account_id, conversation_id: @conversation.id,
                      ai_run_id: nil, event_type: type, payload: payload, status: 'ok')
  end
end
