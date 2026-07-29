# Camada 0 (opt-in) da triagem de turno: decide, SEM chamar LLM, se um turno é trivial demais para
# acordar o supervisor — um "ok"/"obrigada"/emoji solto em REAÇÃO à nossa última mensagem. Custo zero
# (regex + leitura de estado local; nenhuma chamada de modelo). ULTRA-CONSERVADOR: na dúvida, NÃO pula.
# O único modo de falha aceitável é deixar de filtrar (o turno segue o fluxo normal de hoje); nunca o
# contrário (pular algo que precisava de resposta).
#
# Proteção em CAMADAS contra engolir uma resposta legítima (o CaptureJudge trata uma confirmação isolada
# como o dado quando a instrução pede sim/não):
#   1. "sim"/"não" NÃO entram na lista fechada v1 (podem ser o dado de um slot sim/não);
#   2. NUNCA pula quando a etapa atual tem um slot PENDENTE não preenchido (condição c); e
#   3. NUNCA pula quando o turno ANTERIOR fez uma pergunta (ai_last_asked_slot presente, condição e) —
#      cobre pergunta por confirmação/lead_variable em etapa SEM collect, que a (c) não enxerga (conv 412).
class Ai::TrivialTurnGate
  # Lista fechada v1 (comparada contra o texto NORMALIZADO). Deliberadamente SEM "sim"/"não" (camada 1
  # acima) e sem variações com acento/erro de digitação (fica para a v2, com dados de produção).
  CLOSED_LIST = %w[ok okay blz beleza obrigado obrigada valeu 👍 👌].freeze

  # Blocos de emoji bem conhecidos (+ modificadores de tom, ZWJ e variation selectors). CONSERVADOR de
  # propósito: um grafema fora destes blocos faz o texto NÃO contar como "só emoji" (na dúvida sobre um
  # grafema, tratar como não-emoji → não pula).
  EMOJI_CHARS = /[\u{1F1E6}-\u{1FAFF}\u{2600}-\u{27BF}\u{2B00}-\u{2BFF}\u{FE00}-\u{FE0F}\u{200D}\u{20E3}]/

  # → { skip: true|false, reason: String }. skip:true SÓ quando TODAS as condições a–e valem.
  # reason distingue 'closed_list'|'emoji_only' no skip; e a 1ª condição que falhou quando NÃO pula
  # ('not_trivial'|'first_message'|'last_incoming'|'pending_slot'|'awaiting_answer') — telemetria p/ a v2.
  def self.skip?(text:, conversation:, step:)
    # (a) o texto é trivial? (lista fechada OU composto só de emojis)
    trivial = trivial_reason(text)
    return { skip: false, reason: 'not_trivial' } unless trivial

    # (d) + (b): tem de existir uma mensagem NOSSA imediatamente antes desta. Sem mensagem anterior =
    # primeira mensagem da conversa (d); anterior INCOMING = o cliente falou por último (b).
    previous = previous_message(conversation)
    return { skip: false, reason: 'first_message' } if previous.nil?
    return { skip: false, reason: 'last_incoming' } unless previous.outgoing?

    # (c) a etapa atual tem um slot PENDENTE (declarado ∪ inferido, ainda SEM valor)? o "ok" pode ser o
    # dado — NUNCA pula. Um token ABSENT gravado conta como RESOLVIDO (o motor já aceitou a ausência), NÃO
    # pendente: slot já preenchido/resolvido, sem pergunta pendente, cai no skip (economia de fim de conversa).
    return { skip: false, reason: 'pending_slot' } if pending_slot?(step, conversation)

    # (e) o turno ANTERIOR fez uma pergunta (ai_last_asked_slot presente)? então "ok" é a resposta pendente,
    # não ruído de fim — NUNCA pula. Cobre o que (c) NÃO pega: pergunta por confirmação/lead_variable numa
    # etapa SEM collect (StepSlot.attribute nil), onde pending_slot não vê slot algum. (conv 412: "vou
    # finalizar seu pré-cadastro, tudo bem?" -> cliente "ok" foi descartado, ninguém falou por 3 minutos.)
    return { skip: false, reason: 'awaiting_answer' } if awaiting_answer?(conversation)

    { skip: true, reason: trivial }
  end

  # 'closed_list' | 'emoji_only' | nil. A lista fechada casa o texto NORMALIZADO; emoji_only usa o texto
  # CRU (só remove espaços) — se sobrar qualquer grafema não-emoji, não é "só emoji".
  def self.trivial_reason(text)
    return 'closed_list' if CLOSED_LIST.include?(normalize(text))
    return 'emoji_only' if emoji_only?(text)

    nil
  end

  # Normalização para casar a lista fechada: strip, downcase, pontuação → espaço, espaços colapsados.
  # NÃO remove acentos nem corrige digitação (v2). Emoji é categoria SÍMBOLO (não pontuação), então
  # sobrevive à limpeza — "👍" continua "👍" e casa a lista.
  def self.normalize(text)
    text.to_s.strip.downcase.gsub(/[[:punct:]]/, ' ').gsub(/\s+/, ' ').strip
  end

  # O texto sem espaços é composto SOMENTE de emojis? Remove todo grafema de emoji conhecido; se sobrar
  # algo, NÃO é só emoji (conservador). Texto vazio (só espaços) não conta como emoji-only.
  def self.emoji_only?(text)
    compact = text.to_s.gsub(/\s/, '')
    return false if compact.empty?

    compact.gsub(EMOJI_CHARS, '').empty?
  end

  # A mensagem imediatamente ANTERIOR à atual. A mensagem atual (incoming trivial) é a mais recente do
  # canal; pegamos as 2 últimas incoming/outgoing (ignora atividade/nota de sistema) e devolvemos a
  # penúltima. nil quando esta é a 1ª mensagem da conversa (não há penúltima).
  def self.previous_message(conversation)
    recent = conversation.messages
                         .where(message_type: %i[incoming outgoing])
                         .order(:created_at, :id).last(2)
    recent.size < 2 ? nil : recent.first
  end

  # A etapa atual tem um slot PENDENTE — declarado (collect) ∪ inferido (instrução), AINDA sem valor em
  # ai_collected_facts. "Sem valor" = em branco; um token ABSENT gravado conta como RESOLVIDO (o motor já
  # aceitou a ausência), NÃO pendente. step nil/informativa (sem slot) → false. Gap 2: StepSlot.attribute.
  def self.pending_slot?(step, conversation)
    slot = Ai::StepSlot.attribute(step)
    return false if slot.blank?

    facts = conversation.additional_attributes.to_h['ai_collected_facts'] || {}
    facts[slot.to_s].to_s.strip.empty? # em branco = pendente; qualquer valor (inclui ABSENT) = resolvido
  end

  # O turno ANTERIOR pediu um dado: ai_last_asked_slot presente (setado no persist_step_state do turno que
  # perguntou; limpo quando o modelo captura algo). O gate roda ANTES do track_step, então lê o valor do
  # turno anterior — "há uma pergunta aguardando resposta". Presente => "ok" não é ruído de fim.
  def self.awaiting_answer?(conversation)
    conversation.additional_attributes.to_h['ai_last_asked_slot'].to_s.strip.present?
  end
end
