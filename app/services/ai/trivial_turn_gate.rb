# Camada 0 (opt-in) da triagem de turno: decide, SEM chamar LLM, se um turno é trivial demais para
# acordar o supervisor — um "ok"/"obrigada"/emoji solto em REAÇÃO à nossa última mensagem. Custo zero
# (regex + leitura de estado local; nenhuma chamada de modelo). ULTRA-CONSERVADOR: na dúvida, NÃO pula.
# O único modo de falha aceitável é deixar de filtrar (o turno segue o fluxo normal de hoje); nunca o
# contrário (pular algo que precisava de resposta).
#
# Proteção em DUAS camadas contra engolir uma resposta legítima ao slot da etapa (o CaptureJudge trata
# uma confirmação isolada como o dado quando a instrução pede sim/não):
#   1. "sim"/"não" NÃO entram na lista fechada v1 (podem ser o dado de um slot sim/não);
#   2. mesmo itens da lista NUNCA pulam quando a etapa atual coleta um slot (condição c).
class Ai::TrivialTurnGate
  # Lista fechada v1 (comparada contra o texto NORMALIZADO). Deliberadamente SEM "sim"/"não" (camada 1
  # acima) e sem variações com acento/erro de digitação (fica para a v2, com dados de produção).
  CLOSED_LIST = %w[ok okay blz beleza obrigado obrigada valeu 👍 👌].freeze

  # Blocos de emoji bem conhecidos (+ modificadores de tom, ZWJ e variation selectors). CONSERVADOR de
  # propósito: um grafema fora destes blocos faz o texto NÃO contar como "só emoji" (na dúvida sobre um
  # grafema, tratar como não-emoji → não pula).
  EMOJI_CHARS = /[\u{1F1E6}-\u{1FAFF}\u{2600}-\u{27BF}\u{2B00}-\u{2BFF}\u{FE00}-\u{FE0F}\u{200D}\u{20E3}]/

  # → { skip: true|false, reason: String }. skip:true SÓ quando TODAS as condições a–d valem.
  # reason distingue 'closed_list'|'emoji_only' no skip; e a 1ª condição que falhou quando NÃO pula
  # ('not_trivial'|'first_message'|'last_incoming'|'active_slot') — telemetria para calibrar a v2.
  def self.skip?(text:, conversation:, step:)
    # (a) o texto é trivial? (lista fechada OU composto só de emojis)
    trivial = trivial_reason(text)
    return { skip: false, reason: 'not_trivial' } unless trivial

    # (d) + (b): tem de existir uma mensagem NOSSA imediatamente antes desta. Sem mensagem anterior =
    # primeira mensagem da conversa (d); anterior INCOMING = o cliente falou por último (b).
    previous = previous_message(conversation)
    return { skip: false, reason: 'first_message' } if previous.nil?
    return { skip: false, reason: 'last_incoming' } unless previous.outgoing?

    # (c) a etapa atual coleta um slot obrigatório? então NUNCA pula (o "ok" pode ser o dado do slot).
    return { skip: false, reason: 'active_slot' } if collecting_slot?(step)

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

  # A etapa atual coleta um slot OBRIGATÓRIO? (declarado no collect OU inferido da instrução). Mesma
  # fonte usada pela captura determinística (Ai::StepSlot.required_attribute). step nil/informativa → false.
  def self.collecting_slot?(step)
    Ai::StepSlot.required_attribute(step).present?
  end
end
