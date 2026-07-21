# Normaliza LOCALIZAÇÃO recebida como TEXTO (integração nativa do uazapi posta o pin como texto com
# emoji, sem anexo — ver conv 367/368) num Attachment file_type: :location, no MESMO formato do canal
# oficial (Whatsapp::IncomingMessageBaseService#attach_location). Assim o miolo já existente
# (Ai::TurnCapture#capture_attachment) grava localizacao_recebida/coordenadas/link sem mudar nada.
#
# Roda SEQUENCIALMENTE dentro do Ai::GatewayRunJob (antes do Gateway), no MESMO job — nunca como
# listener de message_created (o job é outro processo Sidekiq, sem ordem garantida). Só CRIA o anexo;
# NÃO toca content/content_type da Message (isso dispararia MESSAGE_UPDATED -> webhook de saída).
class Ai::LocationNormalizer
  # Par lat,long em DECIMAL (ponto obrigatório nos dois números) — o ponto é o filtro anti-falso-positivo:
  # "5, 10", "R$ 89,90" (vírgula decimal) e "4998564780" NÃO batem. A faixa é validada em #coord_match.
  COORD_RE = /(-?\d{1,3}\.\d+)\s*,\s*(-?\d{1,3}\.\d+)/
  URL_RE = %r{https?://\S+}i

  # Cria o Attachment de localização a partir do texto da mensagem, se detectar coordenadas válidas.
  # Escopo: só incoming, não privada, e só quando a mensagem NÃO tem anexo nenhum (idempotência +
  # não reprocessar mídia real). Silencioso em erro (nunca derruba o job da IA).
  def self.normalize(message)
    return unless message.respond_to?(:incoming?) && message.incoming?
    return if message.private?
    return if message.attachments.exists?

    loc = parse(message.content)
    return unless loc

    create_attachment(message, loc)
    emit(message, loc)
  rescue StandardError => e
    Rails.logger.error "[Ai::LocationNormalizer] #{e.class}: #{e.message}"
  end

  # { lat:, long:, title:, url: } ou nil. Ancora na LINHA de coordenadas (obrigatória); nome/endereço e
  # link são opcionais (pin comum pode vir só com coordenadas).
  def self.parse(content)
    lines = content.to_s.split("\n")
    coord_line = lines.find { |line| coord_match(line) }
    return nil unless coord_line

    m = coord_match(coord_line)
    others = lines.reject { |line| line.equal?(coord_line) }
    { lat: m[1].to_f, long: m[2].to_f, title: title_of(others), url: url_of(others) }
  end

  # MatchData do par lat,long SÓ quando a faixa é válida (lat [-90,90], long [-180,180]); senão nil.
  def self.coord_match(line)
    m = line.match(COORD_RE)
    return nil unless m && m[1].to_f.between?(-90, 90) && m[2].to_f.between?(-180, 180)

    m
  end

  # Título = as linhas descritivas (sem a de link), com o lixo/emoji do começo removido, unidas por ", ".
  # Ex.: "🏷️ SCNET Internet de Fibra" + "📌 R. Duque de Caxias, 387, ..." -> "SCNET ..., R. Duque ...".
  def self.title_of(lines)
    lines.grep_v(URL_RE)
         .map { |line| line.sub(/\A[^\p{L}\p{N}]+/, '').strip }
         .reject(&:blank?)
         .join(', ')
         .presence
  end

  def self.url_of(lines)
    lines.filter_map { |line| line[URL_RE] }.first
  end

  def self.create_attachment(message, loc)
    message.attachments.create!(
      account_id: message.account_id,
      file_type: :location,
      coordinates_lat: loc[:lat],
      coordinates_long: loc[:long],
      fallback_title: loc[:title],
      external_url: loc[:url]
    )
  end

  def self.emit(message, loc)
    Ai::Event.create!(account_id: message.account_id, conversation_id: message.conversation_id,
                      ai_run_id: nil, event_type: 'location.normalized',
                      payload: { coordinates: "#{loc[:lat]},#{loc[:long]}", title: loc[:title], url: loc[:url] },
                      status: 'ok')
  end
end
