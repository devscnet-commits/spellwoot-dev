# Segredos dos canais que a API de caixas NUNCA devolve inteiros. A lista de caixas é carregada por todo
# navegador logado (e aparece no "Inspecionar"); ali os segredos vão mascarados (SecretMaskingHelper) e o valor
# completo só sai pelo endpoint de revelar (admin, um campo por vez, no clique de "Mostrar"/"Copiar").
# Ao salvar, o eco do valor mascarado que a tela devolve sem alteração é trocado de volta pelo valor real.
module Inboxes::SecretFields
  CHANNEL_FIELDS = {
    'hmac_token' => :hmac_token,
    'secret' => :secret,
    'inbox_identifier' => :identifier,
    'auth_token' => :auth_token,
    'imap_password' => :imap_password,
    'smtp_password' => :smtp_password
  }.freeze
  PROVIDER_CONFIG_FIELDS = %w[api_key webhook_verify_token app_secret api_secret].freeze

  module_function

  def value(channel, field)
    return channel.try(CHANNEL_FIELDS[field]) if CHANNEL_FIELDS.key?(field)
    return channel.try(:provider_config).to_h[field] if PROVIDER_CONFIG_FIELDS.include?(field)

    nil
  end

  def known_field?(field)
    CHANNEL_FIELDS.key?(field) || PROVIDER_CONFIG_FIELDS.include?(field)
  end

  def mask(value)
    value.present? ? SecretMaskingHelper.mask_secret(value) : value
  end

  def masked_provider_config(config)
    config.to_h.to_h { |key, val| [key, PROVIDER_CONFIG_FIELDS.include?(key.to_s) ? mask(val) : val] }
  end

  # Troca, nos params do canal, o eco mascarado (a tela devolve o que recebeu) pelo valor real salvo.
  def restore_masked_echo!(channel, channel_params)
    return if channel_params.blank?

    restore_channel_fields!(channel, channel_params)
    restore_provider_config!(channel, channel_params[:provider_config])
  end

  def restore_channel_fields!(channel, channel_params)
    CHANNEL_FIELDS.each_value do |attribute|
      key = attribute.to_s
      current = channel.try(attribute)
      channel_params[key] = current if channel_params.key?(key) && masked_echo?(channel_params[key], current)
    end
  end

  def restore_provider_config!(channel, config)
    return unless config.respond_to?(:key?)

    PROVIDER_CONFIG_FIELDS.each do |field|
      current = channel.try(:provider_config).to_h[field]
      config[field] = current if config.key?(field) && masked_echo?(config[field], current)
    end
  end

  def masked_echo?(incoming, current)
    current.present? && incoming == mask(current)
  end
end
