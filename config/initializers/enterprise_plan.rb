Rails.application.config.after_initialize do
  begin
    config = InstallationConfig.find_or_initialize_by(name: 'INSTALLATION_PRICING_PLAN')
    if config.value != 'enterprise'
      config.value = 'enterprise'
      config.save!
    end
    Redis::Alfred.delete(Redis::Alfred::CHATWOOT_INSTALLATION_CONFIG_RESET_WARNING)
  rescue StandardError => e
    Rails.logger.error "[ENTERPRISE] Failed to set plan: #{e.message}"
  end
end