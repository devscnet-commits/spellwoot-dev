class IntegrationSettingsService
  PROVIDERS = %w[meta openai evolution_api uazapi bitrix n8n google].freeze

  ENV_KEYS = {
    'meta' => {
      'pixelId'       => 'META_PIXEL_ID',
      'accessToken'   => 'META_CONVERSIONS_API_TOKEN',
      'testEventCode' => 'META_TEST_EVENT_CODE'
    },
    'openai' => {
      'apiKey' => 'OPENAI_API_KEY',
      'model'  => 'OPENAI_DEFAULT_MODEL'
    },
    'evolution_api' => {
      'apiUrl'   => 'EVOLUTION_API_URL',
      'apiKey'   => 'EVOLUTION_API_KEY',
      'instance' => 'EVOLUTION_DEFAULT_INSTANCE'
    },
    'uazapi' => {
      'apiUrl'   => 'UAZAPI_URL',
      'token'    => 'UAZAPI_TOKEN',
      'instance' => 'UAZAPI_DEFAULT_INSTANCE'
    },
    'bitrix' => {
      'webhookUrl' => 'BITRIX_WEBHOOK',
      'token'      => 'BITRIX_TOKEN'
    },
    'n8n' => {
      'webhookUrl' => 'N8N_WEBHOOK_URL',
      'token'      => 'N8N_TOKEN'
    },
    'google' => {
      'clientId'     => 'GOOGLE_CLIENT_ID',
      'clientSecret' => 'GOOGLE_CLIENT_SECRET',
      'refreshToken' => 'GOOGLE_REFRESH_TOKEN'
    }
  }.freeze

  # 3-tier resolution: account config → global config → ENV
  # Each tier fills only keys absent from higher tiers.
  def self.get_config(account_id, provider)
    account_cfg = load_db(account_id, provider)
    global_cfg  = load_db(nil, provider)
    env_cfg     = load_env(provider)

    env_cfg.merge(global_cfg).merge(account_cfg).reject { |_, v| v.blank? }
  end

  # Import current ENV vars for a provider into the global config (account_id = nil).
  # Safe to run multiple times — merges into existing global config.
  def self.import_from_env(provider)
    env_values = load_env(provider)
    return { imported: 0 } if env_values.blank?

    setting = IntegrationSetting.find_or_initialize_by(account_id: nil, provider: provider)
    setting.config = setting.config_hash.merge(env_values).to_json
    setting.save!
    { imported: env_values.size }
  end

  def self.load_db(account_id, provider)
    setting = IntegrationSetting.find_by(account_id: account_id, provider: provider)
    return {} unless setting&.enabled?

    setting.config_hash.reject { |_, v| v.blank? }
  end

  def self.load_env(provider)
    (ENV_KEYS[provider] || {}).each_with_object({}) do |(config_key, env_key), hash|
      value = ENV.fetch(env_key, nil)
      hash[config_key] = value if value.present?
    end
  end
end
