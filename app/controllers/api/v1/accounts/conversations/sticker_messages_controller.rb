# Envia uma figurinha da biblioteca como mensagem de saída.
#
# Inbox com a ponte nativa do uazapi (webhook /chatwoot/webhook): a ponte entrega os anexos
# como IMAGEM (não converte content_type 'sticker' em figurinha). Por isso enviamos a figurinha
# DIRETO pela API do uazapi (/send/media type: sticker) e gravamos a mensagem no Chatwoot já com
# o source_id retornado — assim a ponte enxerga a mensagem como já entregue e não reenvia.
#
# Se não houver token da instância (outro tipo de inbox), cai no fluxo normal: a mensagem é
# criada com content_type 'sticker' e o canal cuida da entrega.
class Api::V1::Accounts::Conversations::StickerMessagesController < Api::V1::Accounts::Conversations::BaseController
  def create
    sticker = Current.account.stickers.find(params[:sticker_id])

    source_id = deliver_sticker_via_uazapi(sticker)

    builder_params = ActionController::Parameters.new(
      message_type: 'outgoing',
      content_type: 'sticker',
      attachments: [sticker.file.blob.signed_id],
      source_id: source_id
    )
    @message = Messages::MessageBuilder.new(Current.user, @conversation, builder_params).perform

    render partial: 'api/v1/models/message', formats: [:json], locals: { message: @message }
  rescue StandardError => e
    render_could_not_create_error(e.message)
  end

  private

  # POST /send/media type: sticker direto na instância uazapi. Retorna o messageid (para gravar
  # como source_id) ou nil quando não se aplica / falha (aí segue o fluxo normal do canal).
  def deliver_sticker_via_uazapi(sticker)
    channel = @conversation.inbox.channel
    token = channel.try(:additional_attributes)&.dig('uazapi_instance_token')
    base = uazapi_base_url(channel)
    return nil if token.blank? || base.blank?

    response = HTTParty.post(
      "#{base}/send/media",
      headers: { 'Content-Type' => 'application/json', 'token' => token },
      body: { number: recipient_identifier, type: 'sticker', file: sticker.download_url }.to_json,
      timeout: 20
    )
    parsed = response.parsed_response
    id = parsed.is_a?(Hash) ? (parsed['messageid'] || parsed['id']) : nil
    Rails.logger.info "[UAZAPI] sticker direct status=#{response.code} id=#{id} body=#{response.body.to_s.first(200)}"
    id.presence&.to_s
  rescue StandardError => e
    Rails.logger.error "[UAZAPI] sticker direct send failed: #{e.class}: #{e.message}"
    nil
  end

  # A instância uazapi responde no mesmo host do webhook (…/chatwoot/webhook/<uuid>).
  def uazapi_base_url(channel)
    url = channel.try(:webhook_url).to_s
    return nil if url.blank?

    uri = URI.parse(url)
    uri.host.present? ? "#{uri.scheme}://#{uri.host}" : nil
  rescue URI::InvalidURIError
    nil
  end

  # Número do destinatário (mesma lógica do SendOnUazapiService): JID vai como está;
  # senão usa o telefone do contato, caindo para o source_id.
  def recipient_identifier
    source_id = @conversation.contact_inbox.source_id.to_s
    return source_id if source_id.include?('@')

    number = @conversation.contact&.phone_number.presence || source_id
    number.gsub(/\D/, '')
  end
end
