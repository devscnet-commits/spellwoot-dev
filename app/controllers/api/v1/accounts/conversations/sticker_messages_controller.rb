# Envia uma figurinha da biblioteca como mensagem de saída. Monta a mensagem com
# content_type 'sticker' + o blob da figurinha (sem reenviar arquivo, via signed_id) e
# deixa o fluxo normal (MessageBuilder -> SendReplyJob) entregar pelo canal.
class Api::V1::Accounts::Conversations::StickerMessagesController < Api::V1::Accounts::Conversations::BaseController
  def create
    sticker = Current.account.stickers.find(params[:sticker_id])

    builder_params = ActionController::Parameters.new(
      message_type: 'outgoing',
      content_type: 'sticker',
      attachments: [sticker.file.blob.signed_id]
    )
    @message = Messages::MessageBuilder.new(Current.user, @conversation, builder_params).perform

    render partial: 'api/v1/models/message', formats: [:json], locals: { message: @message }
  rescue StandardError => e
    render_could_not_create_error(e.message)
  end
end
