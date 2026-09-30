class Webhooks::WhatsappController < ActionController::API
  include MetaTokenVerifyConcern

  before_action :verify_meta_signature!, only: :process_payload

  def process_payload
    if inactive_whatsapp_number?
      Rails.logger.warn("Rejected webhook for inactive WhatsApp number: #{params[:phone_number]}")
      render json: { error: 'Inactive WhatsApp number' }, status: :unprocessable_entity
      return
    end

    Webhooks::WhatsappEventsJob.perform_later(params.to_unsafe_hash)
    head :ok
  end

  private

  # A Meta assina cada webhook (X-Hub-Signature-256 = HMAC-SHA256 do corpo com o App Secret do app). Sem essa
  # conferência, quem descobrisse a URL da caixa injetava mensagens falsas como se fossem de clientes.
  #   - caixa do cadastro Meta (embedded signup): app da plataforma -> WHATSAPP_APP_SECRET do Super Admin;
  #   - caixa manual (app da Meta do próprio cliente): App Secret opcional da caixa (provider_config app_secret).
  # Sem App Secret conhecido (caixa manual sem o campo, 360Dialog), segue aceitando como antes.
  def verify_meta_signature!
    secret = meta_app_secret
    return if secret.blank?

    expected = "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', secret, request.raw_post)}"
    signature = request.headers['X-Hub-Signature-256'].to_s
    return if signature.present? && ActiveSupport::SecurityUtils.secure_compare(signature, expected)

    Rails.logger.warn("[WHATSAPP] Rejected webhook with invalid signature for #{params[:phone_number]}")
    head :unauthorized
  end

  def meta_app_secret
    channel = Channel::Whatsapp.find_by(phone_number: params[:phone_number])
    return if channel.blank? || channel.provider != 'whatsapp_cloud'

    config = channel.provider_config || {}
    return config['app_secret'] if config['app_secret'].present?

    GlobalConfigService.load('WHATSAPP_APP_SECRET', '') if config['source'] == 'embedded_signup'
  end

  def valid_token?(token)
    channel = Channel::Whatsapp.find_by(phone_number: params[:phone_number])
    whatsapp_webhook_verify_token = channel.provider_config['webhook_verify_token'] if channel.present?
    token == whatsapp_webhook_verify_token if whatsapp_webhook_verify_token.present?
  end

  def inactive_whatsapp_number?
    phone_number = params[:phone_number]
    return false if phone_number.blank?

    inactive_numbers = GlobalConfig.get_value('INACTIVE_WHATSAPP_NUMBERS').to_s
    return false if inactive_numbers.blank?

    inactive_numbers_array = inactive_numbers.split(',').map(&:strip)
    inactive_numbers_array.include?(phone_number)
  end
end
