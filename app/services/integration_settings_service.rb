class IntegrationSettingsService
  PROVIDERS = %w[meta openai evolution_api google bitrix n8n].freeze

  # Returns config hash for a provider. DB config takes precedence over ENV.
  def self.get_config(account_id, provider)
    setting = IntegrationSetting.find_by(account_id: account_id, provider: provider)
    db_config = setting ? JSON.parse(setting.config.presence || '{}') : {}
    env_config = env_defaults(provider)
    env_config.merge(db_config.reject { |_, v| v.blank? })
  end

  def self.env_defaults(provider)
    case provider
    when 'meta'
      {
        'pixelId' => ENV.fetch('META_PIXEL_ID', nil),
        'accessToken' => ENV.fetch('META_CONVERSIONS_API_TOKEN', nil),
        'testEventCode' => ENV.fetch('META_TEST_EVENT_CODE', nil)
      }.compact
    else
      {}
    end
  end
end
