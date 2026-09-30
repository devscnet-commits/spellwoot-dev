# Trava do CANAL do plano na criação da caixa — vale para todo caminho que cria caixa, não só para os endpoints
# que lembraram de checar ChannelAvailability. Antes, cadastro do WhatsApp oficial (embedded signup), e-mail por
# OAuth (Google/Microsoft) e a migração de e-mail da Platform API criavam caixa de canal fora do plano.
#
# Só trava conta COM plano (Billing::PlanModules): conta sem plano nunca é barrada aqui. Caixa UazAPI
# (Channel::Api com token da instância) é WhatsApp não oficial, não "Canal API".
module PlanChannelGated
  extend ActiveSupport::Concern

  CHANNEL_KEY_BY_TYPE = {
    'Channel::WebWidget' => 'web_widget',
    'Channel::Api' => 'api',
    'Channel::Email' => 'email',
    'Channel::Telegram' => 'telegram',
    'Channel::Whatsapp' => 'whatsapp',
    'Channel::Sms' => 'sms',
    'Channel::FacebookPage' => 'facebook',
    'Channel::Instagram' => 'instagram'
  }.freeze

  included do
    before_create :enforce_plan_channel!
  end

  private

  def enforce_plan_channel!
    return if account.nil? || plan_limit_exempt?

    return enforce_unofficial_whatsapp! if uazapi_channel?

    key = plan_channel_key
    return if key.nil? || channel_allowed?(key)

    raise CustomExceptions::Plan::FeatureUnavailable.new(message: ChannelAvailability.unavailable_message(key))
  end

  def enforce_unofficial_whatsapp!
    return if channel_allowed?('whatsapp') && Billing::PlanModules.allowed?(account, ChannelAvailability::UNOFFICIAL_WHATSAPP_FLAG)

    raise CustomExceptions::Plan::FeatureUnavailable.new(message: ChannelAvailability.unofficial_whatsapp_unavailable_message)
  end

  def channel_allowed?(key)
    flag = ChannelAvailability::FEATURE_BY_CHANNEL[key]
    flag.nil? || Billing::PlanModules.allowed?(account, flag)
  end

  def uazapi_channel?
    channel_type == 'Channel::Api' && channel.additional_attributes.to_h['uazapi_instance_token'].present?
  end

  # Twilio atende SMS e WhatsApp pelo mesmo canal: o plano vale pelo meio.
  def plan_channel_key
    return (channel.medium.to_s == 'whatsapp' ? 'whatsapp' : 'sms') if channel_type == 'Channel::TwilioSms'

    CHANNEL_KEY_BY_TYPE[channel_type]
  end
end
