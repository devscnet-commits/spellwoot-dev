# Biblioteca de figurinhas da conta (CRUD). O arquivo é enviado via multipart no campo `file`.
class Api::V1::Accounts::StickersController < Api::V1::Accounts::BaseController
  before_action :fetch_sticker, only: [:update, :destroy]

  def index
    render json: stickers.map { |sticker| serialize(sticker) }
  end

  def create
    @sticker = Current.account.stickers.new(sticker_params)
    attach_file(@sticker)
    @sticker.save!
    render json: serialize(@sticker)
  end

  def update
    @sticker.update!(sticker_params)
    attach_file(@sticker)
    render json: serialize(@sticker)
  end

  def destroy
    @sticker.destroy!
    head :ok
  end

  private

  def fetch_sticker
    @sticker = Current.account.stickers.find(params[:id])
  end

  # WebP entra como veio (já é o formato de figurinha, pode ser animada).
  # PNG/JPG/GIF são convertidos para WebP 512x512 transparente; se a conversão
  # falhar, anexa o original como fallback.
  def attach_file(sticker)
    upload = params[:file]
    return if upload.blank?

    if upload.content_type == 'image/webp'
      sticker.file.attach(upload)
      return
    end

    converted = Stickers::ImageConverterService.call(upload)
    if converted
      sticker.file.attach(io: converted, filename: webp_filename(upload), content_type: 'image/webp')
    else
      sticker.file.attach(upload)
    end
  end

  def webp_filename(upload)
    base = File.basename(upload.original_filename.to_s, '.*').presence || 'sticker'
    "#{base.parameterize.presence || 'sticker'}.webp"
  end

  def sticker_params
    params.permit(:name)
  end

  def stickers
    Current.account.stickers.order(created_at: :desc)
  end

  def serialize(sticker)
    {
      id: sticker.id,
      name: sticker.name,
      file_url: sticker.file_url,
      created_at: sticker.created_at
    }
  end
end
