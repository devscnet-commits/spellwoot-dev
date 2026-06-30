# Biblioteca de figurinhas (stickers) por conta. Cada figurinha guarda um arquivo (WebP/PNG/...)
# via ActiveStorage e é reutilizada no envio manual pelo atendente. O envio em si vira uma
# mensagem com content_type 'sticker' + anexo, e o UazapiService entrega como figurinha.
class Sticker < ApplicationRecord
  include Rails.application.routes.url_helpers

  ACCEPTABLE_TYPES = %w[image/webp image/png image/jpeg image/gif].freeze
  MAX_SIZE = 2.megabytes

  belongs_to :account
  has_one_attached :file

  validates :account, presence: true
  validate :file_attached
  validate :acceptable_file

  # URL com redirect (uso no dashboard).
  def file_url
    file.attached? ? url_for(file) : ''
  end

  # URL direta do blob (uso por serviços externos, ex.: uazapi baixar o arquivo).
  def download_url
    ActiveStorage::Current.url_options = Rails.application.routes.default_url_options if ActiveStorage::Current.url_options.blank?
    file.attached? ? file.blob.url : ''
  end

  private

  def file_attached
    errors.add(:file, 'must be attached') unless file.attached?
  end

  def acceptable_file
    return unless file.attached?

    errors.add(:file, 'type not supported') unless ACCEPTABLE_TYPES.include?(file.blob.content_type)
    errors.add(:file, 'too large') if file.blob.byte_size.to_i > MAX_SIZE
  end
end
