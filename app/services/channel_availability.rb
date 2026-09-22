# Quais canais uma conta pode CRIAR, segundo o plano dela.
#
# Antes só WhatsApp e API tinham enforcement de servidor (Api::V1::Accounts::InboxesController
# #allowed_channel_types); os demais eram escondidos apenas no front (rota/sidebar), e Telegram e SMS
# não tinham nem flag. Na prática a tabela de planos era decorativa para 7 dos 9 canais: bastava
# chamar a API para criar um canal que o plano não inclui.
#
# Lê o BITMASK da conta, não o plano direto: conta SEM assinatura não pode ser barrada (FeatureGate
# nega por padrão, e contas internas/dev não têm plano). O bitmask é a projeção do plano
# (Plan#sync_features_to!) para quem tem assinatura, e o default de config/features.yml para quem não
# tem — exatamente a semântica desejada aqui.
class ChannelAvailability
  # Canal -> flag de conta. Só os canais que a tabela de planos v2 diferencia entram; os demais
  # (line, tiktok, twitter) continuam sem gate — ligá-los sem um campo no plano criaria um toggle
  # que não corresponde a nada.
  FEATURE_BY_CHANNEL = {
    'web_widget' => 'channel_website',
    'api' => 'channel_api',
    'email' => 'channel_email',
    'telegram' => 'channel_telegram',
    'whatsapp' => 'channel_whatsapp',
    'sms' => 'channel_sms',
    'facebook' => 'channel_facebook',
    'instagram' => 'channel_instagram'
  }.freeze

  def self.available?(account, channel_type)
    flag = FEATURE_BY_CHANNEL[channel_type.to_s]
    return true if flag.blank?

    account.present? && account.feature_enabled?(flag)
  end

  # Só os canais do plano, preservando a ordem recebida.
  def self.filter(account, channel_types)
    channel_types.select { |type| available?(account, type) }
  end

  def self.unavailable_message(channel_type)
    "O canal #{channel_type} não está incluído no plano desta conta."
  end
end
