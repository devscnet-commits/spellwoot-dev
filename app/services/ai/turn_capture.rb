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
  def initialize(conversation:, persister:, agent: nil)
    @conversation = conversation
    @persister = persister
    @agent = agent
    @claimed = []
  end

  # true = ESTE run ganhou a mensagem (deve capturar/avançar). false = OUTRA instância/processo já venceu
  # o mesmo id (no-op). Sem message_id (follow-up/teste) => true (sem idempotência). Fail-open em erro
  # (melhor capturar que travar).
  def claim(message)
    id = message.respond_to?(:id) ? message.id : nil
    return true if id.blank?
    # @claimed contém os ids que ESTA instância já venceu neste run; claim repetido do mesmo turno é
    # no-op-win (design da PR #281: o early-claim do worker no Gateway e o claim do track_step
    # compartilham o MESMO turn_capture memoizado). Retornar false aqui abortava o track_step ANTES de
    # persistir o índice (bug do ai_step_index nil). A idempotência entre instâncias/processos (2º
    # binding / re-run / concorrência) continua garantida pelo atomic_claim (IS DISTINCT FROM).
    return true if @claimed.include?(id)

    won = atomic_claim(id)
    @claimed << id if won
    won
  end

  # Captura o dado desta mensagem para o slot corrente (anexo -> modelo -> texto cru). department é
  # necessário para o espelhamento em custom_attributes.
  # rubocop:disable Metrics/ParameterLists -- seam de captura: o quê (step, decision) + input da vez
  # (message_text agrupado, message p/ anexo/idempotência) + department (espelhamento) + judge_result
  # (worker pré-rodado, camada 3). Mesmo motivo do track_step; agrupar rippla por specs + Gateway.
  def capture(step, decision, message_text, message, department, judge_result: nil)
    # rubocop:enable Metrics/ParameterLists
    # Gap 2: a CAPTURA é governada por StepSlot.attribute (declarado ∪ INFERIDO), independente de
    # obrigatoriedade — assim slot OPCIONAL também é capturado determinísticamente (antes usava
    # required_attribute, que devolvia nil p/ opcional e pulava a captura).
    slot = Ai::StepSlot.attribute(step)
    # BUG 3: o anexo SEMPRE grava os fatos determinísticos (mesmo em etapa sem slot). O preenchimento do
    # slot é DETERMINÍSTICO pela chave (#attachment_slot_value). Retorna :filled (preencheu o slot -> é a
    # captura desta mensagem, pula o texto), :facts_only (havia anexo mas NÃO preencheu -> segue para o
    # texto/legenda) ou nil (sem anexo).
    attachment = capture_attachment(message, slot, department)
    return if attachment == :filled

    # Gap 1: recusa/ausência de slot. DEPOIS do anexo (anexo que preenche é dado real e vence — o cliente
    # mandou o documento E escreveu "não tenho" na mesma msg). O StepResolver roteia opcional-satisfaz /
    # obrigatório-recusa a partir deste sinal.
    return { declined: true } if slot && declined_turn?(step, slot, decision, message_text)

    return unless slot

    attrs = decision['attributes'].is_a?(Hash) ? reject_blank(decision['attributes']) : {}
    return capture_on_mismatch(step, slot, attrs, message_text, department, judge_result) unless attrs.empty?

    # Modelo MUDO. (b) anexo que NÃO preencheu o slot e SEM texto: o cliente mandou ALGO (não sumiu). Gap 4
    # v2: anexo-que-não-preenche é NÃO-RESPOSTA, não declínio — vira :no_attempt (não conta contra o
    # cliente, mesma classe da pergunta). Repetir anexo numa etapa com slot é pego pelo teto ABSOLUTO
    # (ai_step_turns), não mais pela rede de recusa. Com legenda, o texto é capturado logo abaixo (inalterado).
    return refuse_no_attempt(slot, 'attachment_no_slot') if attachment == :facts_only && message_text.to_s.strip.empty?

    capture_from_text(step, slot, decision, message_text, department, judge_result)
  end

  # Modelo devolveu attributes: se algum bate com o slot corrente, o Gateway#persist_attributes grava
  # (Opção B) — nada aqui. Se NENHUM bate -> mismatch (evento inalterado); no modo 'always' o juiz ainda
  # julga o turno.
  def capture_on_mismatch(step, slot, attrs, message_text, department, judge_result = nil) # rubocop:disable Metrics/ParameterLists
    return nil if attrs.key?(slot)

    emit('slot.model_key_mismatch', { expected: slot, got: attrs.keys })
    return capture_by_judge(step, slot, message_text, department, judge_result) if judge_mode == 'always'

    nil
  end

  # Modelo MUDO (sem attributes): worker de julgamento LIGADO decide (when_silent/always); DESLIGADO cai
  # no caminho determinístico do #269 (SlotCollector, extractor OU cru), BIT A BIT como antes. O worker
  # só entra com texto presente — mensagem vazia (cliente sumido) segue pela rede de segurança do #259.
  def capture_from_text(step, slot, decision, message_text, department, judge_result = nil) # rubocop:disable Metrics/ParameterLists
    return capture_by_judge(step, slot, message_text, department, judge_result) if judge_active? && message_text.present?

    cap = Ai::SlotCollector.new(conversation: @conversation).capture_value(step, slot, decision, message_text)
    return unless cap
    return refuse_no_attempt(slot, cap[:type]) if cap[:no_attempt]

    @persister.persist_attributes({ slot => cap[:value] }, department)
    emit('slot.captured', { attribute: slot, source: cap[:source] })
    nil
  end

  private

  # Gap 1: o turno é uma recusa do dado deste slot? Passa o valor do modelo (attributes[slot]), o texto do
  # turno e o tipo/opções efetivos do slot p/ o guard (d) do Ai::SlotAbsence (valor extraível vence).
  def declined_turn?(step, slot, decision, message_text)
    value = decision['attributes'].is_a?(Hash) ? decision['attributes'][slot] : nil
    type = Ai::SlotCollector.new(conversation: @conversation).effective_type(step, slot)
    Ai::SlotAbsence.declined?(value: value, text: message_text, type: type, options: Ai::StepSlot.options(step))
  end

  # Modo de acionamento do worker (worker_overrides['capture_judge']['mode']): 'off' (PADRÃO — nasce
  # desligado), 'when_silent' (roda quando o modelo não devolveu attributes) ou 'always' (também na
  # divergência de chave). Sem perfil/sem config => 'off'.
  def judge_mode
    @agent&.operation_profile&.worker(:capture_judge)&.dig('mode').to_s.presence || 'off'
  end

  # Worker roda no caminho "modelo mudo"? (when_silent e always).
  def judge_active?
    %w[when_silent always].include?(judge_mode)
  end

  # (B)+(C)+(D) Julga o turno pelo worker e age pelo status: answered -> grava normalizado (source
  # 'judge'); malformed -> grava como veio (source 'judge_raw', a confirmação-única cuida).
  # Gap 4 v2 (conserto da conv 389): not_an_answer (pergunta/digressão) e failed (erro de sistema) NÃO são
  # recusa — viram :no_attempt (não contam contra o cliente; a resposta do modelo segue; o teto ABSOLUTO
  # pega quem só pergunta). O DECLÍNIO genuíno é detectado ANTES pelo Ai::SlotAbsence (fonte única). O juiz
  # não alimenta mais a rede de recusa.
  # judge_result: quando o Gateway já rodou o worker ANTES da decisão (camada 3), REUSA o resultado —
  # roda o worker UMA vez por turno. nil (chamada direta em spec / worker não pré-rodado) => chama agora.
  def capture_by_judge(step, slot, message_text, department, judge_result = nil)
    result = judge_result || Ai::Workers::CaptureJudge.judge(
      step: step, slot: slot, message_text: message_text,
      profile: @agent&.operation_profile, conversation: @conversation
    )
    case result[:status]
    when 'answered'
      persist_judged(slot, normalize_judged(result[:value], step, slot), department, 'judge', 'answered')
    when 'malformed'
      persist_judged(slot, result[:value], department, 'judge_raw', 'malformed')
    when 'not_an_answer'
      # Débito do fraseado novo (Design A, SlotAbsence como fonte única): um declínio que a lista fechada
      # NÃO reconhece cai aqui como :no_attempt e, em slot opcional, faz a IA repetir o pedido até o
      # absoluto (versão lenta do bug). Não muda o roteamento, mas quando o juiz diz que NÃO é pergunta
      # (asks_about 'nada') e o texto PARECE declínio, emite p/ crescer a lista com dado real.
      probe_unmatched_decline(slot, message_text) if result[:asks_about].to_s == 'nada'
      refuse_no_attempt(slot, 'not_an_answer')
    else
      emit('judge.failed', { attribute: slot, status: result[:status], reason: result[:reason] })
      refuse_no_attempt(slot, 'judge_failed')
    end
  end

  # Observabilidade do débito do fraseado novo (item 2): o texto parece um declínio que o SlotAbsence não
  # casou? Emite o texto normalizado (curto, baixa-PII) p/ alimentar o crescimento das listas EXACT/ANCHORED
  # — sem isso a lista nunca melhora porque ninguém vê o que ela perde. NÃO altera o roteamento (já é
  # :no_attempt); é só sinal.
  def probe_unmatched_decline(slot, message_text)
    return unless Ai::SlotAbsence.looks_like_decline?(message_text)

    emit('slot.possible_decline_unmatched',
         { attribute: slot, text: Ai::SlotExtractor.normalize(message_text.to_s).first(60) })
  end

  def persist_judged(slot, value, department, source, status)
    @persister.persist_attributes({ slot => value }, department)
    emit('slot.captured', { attribute: slot, source: source, status: status })
    nil
  end

  # (C) NORMALIZAÇÃO, não bloqueio: se o tipo é reconhecível, normaliza pelo extractor; se ele não
  # reconhece o tipo OU não casa, usa o value do worker COMO VEIO (o extractor nunca descarta o aprovado).
  def normalize_judged(value, step, slot)
    type = Ai::SlotCollector.new(conversation: @conversation).effective_type(step, slot)
    return value unless Ai::SlotExtractor.known_format?(type)

    Ai::SlotExtractor.extract(attribute_type: type, text: value, options: Ai::StepSlot.options(step)).presence || value
  end

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

  # Chaves cujo VALOR é o nome do arquivo enviado (o anexo É a resposta da etapa). type_for_key tem
  # PRECEDÊNCIA: nome de arquivo nunca é cpf/e-mail/telefone -> se a chave é um desses, não preenche.
  ATTACHMENT_KEY_RE = /documento|comprovante|foto|imagem|anexo|arquivo/i

  # BUG 3: grava fatos determinísticos do anexo (via persist_attributes -> espelhamento) e preenche o
  # slot corrente SÓ quando a chave aceita anexo (#attachment_slot_value). Retorna :filled (preencheu o
  # slot -> é a captura da mensagem), :facts_only (havia anexo, não preencheu) ou nil (sem anexo).
  def capture_attachment(message, slot, department)
    facts, kind, slot_value = attachment_facts(message, slot)
    return nil unless facts

    @persister.persist_attributes(facts, department)
    @persister.persist_attributes({ slot => slot_value }, department) if slot_value
    emit('attachment.captured', { kind: kind, attribute: (slot_value ? slot : nil) })
    slot_value ? :filled : :facts_only
  end

  # [facts, kind, slot_value] do anexo (metadados — sem depender do MediaProcessor), ou [nil, nil, nil].
  # Localização só grava fatos (nunca preenche slot). Documento/imagem preenchem o slot corrente com o
  # nome do arquivo SÓ quando a chave aceita anexo (#attachment_slot_value); senão slot_value = nil.
  def attachment_facts(message, slot)
    att = Array(message.try(:attachments)).find { |a| %w[location file image].include?(a.file_type.to_s) }
    return [nil, nil, nil] unless att

    if att.file_type.to_s == 'location'
      facts = { 'localizacao_recebida' => true,
                'localizacao_coordenadas' => "#{att.coordinates_lat},#{att.coordinates_long}" }
      facts['localizacao_link'] = att.external_url if att.external_url.present?
      [facts, 'location', nil]
    else
      name = attachment_name(att)
      [{ 'documento_recebido' => true, 'documento_arquivo' => name }, att.file_type.to_s,
       attachment_slot_value(slot, name)]
    end
  end

  # Valor com que o anexo preenche o slot, ou nil (não preenche) — determinístico pela CHAVE:
  #  1. type_for_key(slot) validável (cpf/email/phone) -> nil (nome de arquivo nunca é esses).
  #  2. chave indica anexo (ATTACHMENT_KEY_RE) -> o nome do arquivo.
  #  3. qualquer outra chave (ou sem slot) -> nil.
  def attachment_slot_value(slot, name)
    return nil if slot.blank?
    return nil if Ai::SlotExtractor.type_for_key(slot)

    ATTACHMENT_KEY_RE.match?(slot) ? name : nil
  end

  def attachment_name(att)
    (att.file.attached? ? att.file.blob.filename.to_s : att.fallback_title.to_s).presence || 'anexo'
  end

  def reject_blank(attrs)
    attrs.reject { |_k, v| v.to_s.strip.empty? }
  end

  # (#269) O cru foi RECUSADO por não ser tentativa de resposta (slot de tipo conhecido sem tentativa).
  # Observabilidade + sinal (:no_attempt) para o StateManager NÃO contar travamento neste turno. Não
  # persiste nada. (A recusa do JUIZ é tratada em capture_by_judge — devolve { refusal: ... }.)
  def refuse_no_attempt(slot, type)
    emit('slot.no_attempt', { attribute: slot, type: type })
    :no_attempt
  end

  def emit(type, payload)
    Ai::Event.create!(account_id: @conversation.account_id, conversation_id: @conversation.id,
                      ai_run_id: nil, event_type: type, payload: payload, status: 'ok')
  end
end
