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

  def self.test_connection(provider, config)
    case provider
    when 'uazapi'
      test_uazapi(config)
    when 'evolution_api'
      test_evolution_api(config)
    else
      { ok: false, message: 'Teste de conexão não disponível para este provedor.' }
    end
  rescue StandardError => e
    { ok: false, message: e.message }
  end

  def self.load_db(account_id, provider)
    setting = IntegrationSetting.find_by(account_id: account_id, provider: provider)
    return {} unless setting&.enabled?

    setting.config_hash.reject { |_, v| v.blank? }
  end

  def self.test_uazapi(config)
    api_url = config['apiUrl'].to_s.chomp('/')
    token   = config['token']
    return { ok: false, message: 'URL da API não configurada.' } if api_url.blank?
    return { ok: false, message: 'Token não configurado.' } if token.blank?

    response = HTTParty.get("#{api_url}/instance/status", headers: { 'token' => token, 'Accept' => 'application/json' }, timeout: 10)
    if response.success?
      body = response.parsed_response
      { ok: true, message: 'Conexão bem-sucedida.', status: body }
    else
      { ok: false, message: "Erro #{response.code}: #{response.message}" }
    end
  end

  def self.test_evolution_api(config)
    api_url  = config['apiUrl'].to_s.chomp('/')
    api_key  = config['apiKey']
    instance = config['instance']
    return { ok: false, message: 'URL da API não configurada.' } if api_url.blank?
    return { ok: false, message: 'API Key não configurada.' } if api_key.blank?

    path     = instance.present? ? "#{api_url}/instance/fetchInstances?instanceName=#{instance}" : "#{api_url}/instance/fetchInstances"
    response = HTTParty.get(path, headers: { 'apikey' => api_key, 'Accept' => 'application/json' }, timeout: 10)
    if response.success?
      { ok: true, message: 'Conexão bem-sucedida.' }
    else
      { ok: false, message: "Erro #{response.code}: #{response.message}" }
    end
  end

  def self.load_env(provider)
    (ENV_KEYS[provider] || {}).each_with_object({}) do |(config_key, env_key), hash|
      value = ENV.fetch(env_key, nil)
      hash[config_key] = value if value.present?
    end
  end
end
