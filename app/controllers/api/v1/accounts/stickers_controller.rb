# Biblioteca de figurinhas da conta (CRUD). O arquivo é enviado via multipart no campo `file`.
class Api::V1::Accounts::StickersController < Api::V1::Accounts::BaseController
  before_action :fetch_sticker, only: [:update, :destroy]

  def index
    render json: stickers.map { |sticker| serialize(sticker) }
  end

  def create
    @sticker = Current.account.stickers.new(sticker_params)
    @sticker.file.attach(params[:file]) if params[:file].present?
    @sticker.save!
    render json: serialize(@sticker)
  end

  def update
    @sticker.update!(sticker_params)
    @sticker.file.attach(params[:file]) if params[:file].present?
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
