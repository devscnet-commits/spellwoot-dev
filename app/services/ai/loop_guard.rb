# Rede de segurança anti-loop de repergunta (defesa em profundidade, mesmo em departments mal
# configurados). Compara o reply_text que a IA vai enviar com as 2 últimas respostas de
# decision='reply' desta conversa (lidas de ai_runs.decision, já persistido — zero coluna nova).
#
# É "loop" quando as 3 respostas são muito parecidas (Jaccard de tokens de CONTEÚDO, com stopwords
# pt-BR removidas, >= THRESHOLD) E o cliente respondeu (incoming) ENTRE cada uma delas — senão é
# silêncio/follow-up, não loop. Threshold calibrado com o caso real do bug (paráfrases ~0.63–0.71),
# não teórico.
class Ai::LoopGuard
  THRESHOLD = 0.6
  COMPARE_LAST = 2 # a nova resposta precisa ser similar às DUAS últimas (AND)

  # Stopwords pt-BR básicas (preposições, pronomes, artigos e formas leves de ser/estar/ter). Removê-las
  # foca o Jaccard no CONTEÚDO — sem isso, trocar "deseja"/"está interessado" derruba a similaridade e
  # o loop parafraseado passa batido.
  STOPWORDS = %w[
    a o as os um uns uma umas de do da dos das no na nos nas em para por com sem sob
    e ou que se ao à aos às
    você voce vocês voces eu tu ele ela nós nos eles elas me te lhe vos lhes
    meu minha seu sua isso isto este esta esse essa aquele aquela
    é sou estou está estamos estão estava ser estar são foi era
    tem têm temos ter há não sim
  ].to_set.freeze

  def initialize(conversation:, current_run: nil)
    @conversation = conversation
    @current_run = current_run
  end

  # true = provável loop (a resposta nova repete as 2 anteriores apesar de o cliente ter respondido).
  def loop?(reply_text)
    new_tokens = tokenize(reply_text)
    return false if new_tokens.empty?

    previous = recent_ai_replies(COMPARE_LAST)
    return false if previous.size < COMPARE_LAST
    return false unless previous.all? { |r| jaccard(new_tokens, tokenize(r[:text])) >= THRESHOLD }

    customer_spoke_between?(previous.map { |r| r[:created_at] })
  rescue StandardError => e
    Rails.logger.error "[Ai::LoopGuard] conv=#{@conversation&.id} #{e.class}: #{e.message}"
    false
  end

  private

  # As últimas N respostas de decision='reply' nos ai_runs (mais recentes primeiro), excluindo o run
  # atual. Varre uma janela recente e filtra só os replies com texto.
  def recent_ai_replies(limit)
    scope = Ai::Run.where(conversation_id: @conversation.id, run_type: 'decision')
    scope = scope.where.not(id: @current_run.id) if @current_run&.id

    scope.order(created_at: :desc).limit(20).filter_map do |run|
      decision = run.decision
      next unless decision.is_a?(Hash) && decision['decision'] == 'reply'

      text = decision['reply_text'].to_s.strip
      next if text.blank?

      { text: text, created_at: run.created_at }
    end.first(limit)
  end

  # Houve incoming do cliente ENTRE cada resposta comparada E depois da mais recente? Garante que o
  # cliente respondeu entre as repetições (não é silêncio). `times` = created_at das respostas.
  def customer_spoke_between?(times)
    ordered = times.compact.sort # crescente: [mais antiga ... mais recente]
    return false if ordered.size < COMPARE_LAST

    ordered.each_cons(2).all? { |older, newer| incoming_between?(older, newer) } &&
      incoming_after?(ordered.last)
  end

  def incoming_between?(from, to)
    @conversation.messages.incoming.where('created_at > ? AND created_at < ?', from, to).exists?
  end

  def incoming_after?(from)
    @conversation.messages.incoming.where('created_at > ?', from).exists?
  end

  # Tokens de conteúdo: minúsculas, pontuação -> espaço, split, sem vazios e sem stopwords. Set.
  def tokenize(text)
    text.to_s.downcase
        .gsub(/[[:punct:]]/, ' ')
        .split(/\s+/)
        .reject { |word| word.blank? || STOPWORDS.include?(word) }
        .to_set
  end

  # Jaccard: |interseção| / |união| dos conjuntos de tokens.
  def jaccard(set_a, set_b)
    return 0.0 if set_a.empty? || set_b.empty?

    union = (set_a | set_b).size
    union.zero? ? 0.0 : (set_a & set_b).size.to_f / union
  end
end
