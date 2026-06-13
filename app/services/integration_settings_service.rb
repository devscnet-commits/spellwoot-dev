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
      'apiUrl'         => 'UAZAPI_BASE_URL',
      'token'          => 'UAZAPI_ADMIN_TOKEN',
      'webhookBaseUrl' => 'UAZAPI_WEBHOOK_BASE_URL'
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

  def self.sync_instances(account_id, provider)
    case provider
    when 'uazapi'
      sync_uazapi_instances(account_id)
    else
      { ok: false, message: 'Sincronização não disponível para este provedor.' }
    end
  rescue StandardError => e
    { ok: false, message: e.message }
  end

  def self.test_connection(provider, config)
    case provider
    when 'uazapi'
      test_uazapi(config)
    when 'evolution_api'
      test_evolution_api(config)
    when 'openai'
      test_openai(config)
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

  def self.sync_uazapi_chatwoot(config, account, user)
    api_url  = config['apiUrl'].to_s.chomp('/')
    token    = config['token']
    instances = Array(config['instances']).select { |i| i['instanceName'].present? && i['chatwootInboxId'].present? }

    return { ok: false, message: 'URL do servidor não configurada.' } if api_url.blank?
    return { ok: false, message: 'Token não configurado.' }           if token.blank?
    return { ok: false, message: 'Nenhuma conexão instância→inbox configurada.' } if instances.empty?

    chatwoot_url = ENV.fetch('FRONTEND_URL', 'https://app.chatwoot.com').chomp('/')
    access_token = user.access_token&.token
    return { ok: false, message: 'Token de acesso do usuário não encontrado.' } if access_token.blank?

    results = instances.map do |inst|
      inbox_id = inst['chatwootInboxId'].to_i
      inbox    = Inbox.find_by(id: inbox_id, account_id: account.id)
      next { instance: inst['instanceName'], ok: false, message: "Inbox #{inbox_id} não encontrada." } unless inbox

      body = {
        enabled: true,
        url: chatwoot_url,
        access_token: access_token,
        account_id: account.id,
        inbox_id: inbox_id,
        ignore_groups: false,
        sign_messages: true,
        create_new_conversation: false
      }

      response = HTTParty.put(
        "#{api_url}/chatwoot/config",
        headers: { 'token' => token, 'Content-Type' => 'application/json', 'Accept' => 'application/json' },
        body: body.to_json,
        timeout: 15
      )

      unless response.success?
        next { instance: inst['instanceName'], ok: false, message: "Erro #{response.code}" }
      end

      webhook_url = response.parsed_response['chatwoot_inbox_webhook_url']
      inbox.update!(webhook_url: webhook_url) if webhook_url.present?
      { instance: inst['instanceName'], ok: true, webhook_url: webhook_url }
    end.compact

    failed  = results.reject { |r| r[:ok] }
    success = results.select { |r| r[:ok] }

    if failed.empty?
      { ok: true, message: "#{success.size} conexão(ões) configurada(s) com sucesso!" }
    elsif success.any?
      { ok: false, message: "#{success.size} ok, #{failed.size} com erro: #{failed.map { |f| f[:instance] }.join(', ')}" }
    else
      { ok: false, message: "Falha em todas as conexões: #{failed.map { |f| "#{f[:instance]}: #{f[:message]}" }.join(' | ')}" }
    end
  end

  def self.test_openai(config)
    api_key = config['apiKey']
    return { ok: false, message: 'API Key não configurada.' } if api_key.blank?

    response = HTTParty.get('https://api.openai.com/v1/models',
                            headers: { 'Authorization' => "Bearer #{api_key}" }, timeout: 10)
    if response.success?
      model = config['model'].presence
      known = Array(response.parsed_response['data']).map { |m| m['id'] }
      if model.present? && known.exclude?(model)
        { ok: true, message: "Chave válida, mas o modelo \"#{model}\" não foi encontrado na sua conta." }
      else
        { ok: true, message: 'Conexão bem-sucedida. Chave válida.' }
      end
    elsif response.code == 401
      { ok: false, message: 'Chave inválida ou revogada (401).' }
    else
      { ok: false, message: "Erro #{response.code}: #{response.message}" }
    end
  end

  def self.test_uazapi(config)
    api_url = config['apiUrl'].to_s.chomp('/')
    token   = config['token']
    return { ok: false, message: 'URL da API não configurada.' } if api_url.blank?
    return { ok: false, message: 'Token não configurado.' } if token.blank?

    # Admin listing on UazAPI is GET /instance/all with the admintoken header — the
    # instance-level 'token' header on /instance 404s.
    response = HTTParty.get("#{api_url}/instance/all", headers: { 'admintoken' => token, 'Accept' => 'application/json' }, timeout: 10)
    if response.success?
      instances = Array(response.parsed_response)
      { ok: true, message: "Conexão bem-sucedida. #{instances.size} instância(s) encontrada(s)." }
    else
      { ok: false, message: uazapi_error_message(response) }
    end
  end

  # UazAPI rejects a token that belongs to a different server with 401/403. After switching
  # the server URL the token must be re-entered, so spell that out instead of a raw "Erro 401".
  def self.uazapi_error_message(response)
    return "Token rejeitado pelo servidor (#{response.code}). Confirme o Admin Token deste servidor — ao trocar a URL, reenvie o token (Redefinir)." if [401, 403].include?(response.code)

    "Erro #{response.code}: #{response.message}"
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

  def self.sync_uazapi_instances(account_id)
    config  = get_config(account_id, 'uazapi')
    api_url = config['apiUrl'].to_s.chomp('/')
    token   = config['token']

    return { ok: false, message: 'URL do servidor não configurada.' } if api_url.blank?
    return { ok: false, message: 'Token não configurado.' }           if token.blank?

    response = HTTParty.get(
      "#{api_url}/instance/all",
      headers: { 'admintoken' => token, 'Accept' => 'application/json' },
      timeout: 15
    )

    unless response.success?
      return { ok: false, message: uazapi_error_message(response) }
    end

    instances = Array(response.parsed_response)
    synced = 0
    synced_names = []

    instances.each do |inst|
      instance_name = inst['instanceName'] || inst['name'] || inst['id'].to_s
      next if instance_name.blank?

      pi = ProviderInstance.find_or_initialize_by(
        account_id: account_id,
        provider:   'uazapi',
        instance_name: instance_name
      )
      pi.assign_attributes(
        instance_id:  (inst['id'] || inst['instanceId']).to_s.presence,
        # UazAPI exposes the number as owner/jid ("5549...@s.whatsapp.net") on /instance/all.
        phone_number: (inst['phone'] || inst['phoneNumber'] || inst['owner'] || inst['jid']).to_s.split('@').first.presence,
        status:       inst['status'] || 'unknown',
        raw_data:     inst
      )
      pi.save!
      synced += 1
      synced_names << instance_name
    end

    # Reconcile: drop cached instances the current server no longer reports (e.g. after
    # switching the server URL) so the list mirrors the server instead of accumulating.
    stale = ProviderInstance.where(account_id: account_id, provider: 'uazapi')
    stale = stale.where.not(instance_name: synced_names) if synced_names.any?
    stale.delete_all

    { ok: true, message: "#{synced} instância(s) sincronizada(s).", count: synced }
  end

  def self.load_env(provider)
    (ENV_KEYS[provider] || {}).each_with_object({}) do |(config_key, env_key), hash|
      value = ENV.fetch(env_key, nil)
      hash[config_key] = value if value.present?
    end
  end
end
