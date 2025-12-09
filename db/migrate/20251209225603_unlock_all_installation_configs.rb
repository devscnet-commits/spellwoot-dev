class UnlockAllInstallationConfigs < ActiveRecord::Migration[7.1]
  def up
    # Desbloqueia todas as configurações existentes
    # Isso permite que todas as installation_configs sejam editáveis no dashboard
    updated_count = InstallationConfig.where(locked: true).update_all(locked: false)
    total_configs = InstallationConfig.count
    
    Rails.logger.info "✓ #{updated_count} de #{total_configs} configurações foram desbloqueadas"
    puts "✓ #{updated_count} de #{total_configs} configurações foram desbloqueadas"
    
    # Atualiza INSTALLATION_PRICING_PLAN para 'enterprise'
    pricing_plan = InstallationConfig.find_by(name: 'INSTALLATION_PRICING_PLAN')
    if pricing_plan
      pricing_plan.update!(value: 'enterprise')
      Rails.logger.info "✓ INSTALLATION_PRICING_PLAN atualizado para 'enterprise'"
      puts "✓ INSTALLATION_PRICING_PLAN atualizado para 'enterprise'"
    end
    
    # Atualiza INSTALLATION_PRICING_PLAN_QUANTITY para 10000
    pricing_quantity = InstallationConfig.find_by(name: 'INSTALLATION_PRICING_PLAN_QUANTITY')
    if pricing_quantity
      pricing_quantity.update!(value: 10_000)
      Rails.logger.info "✓ INSTALLATION_PRICING_PLAN_QUANTITY atualizado para 10000"
      puts "✓ INSTALLATION_PRICING_PLAN_QUANTITY atualizado para 10000"
    end
  end

  def down
    # Restaura INSTALLATION_PRICING_PLAN para 'community'
    pricing_plan = InstallationConfig.find_by(name: 'INSTALLATION_PRICING_PLAN')
    pricing_plan&.update!(value: 'community')
    
    # Restaura INSTALLATION_PRICING_PLAN_QUANTITY para 0
    pricing_quantity = InstallationConfig.find_by(name: 'INSTALLATION_PRICING_PLAN_QUANTITY')
    pricing_quantity&.update!(value: 0)
    
    # Re-bloqueia as configurações usando os valores padrão do installation_config.yml
    # Isso restaura o estado original das configurações
    config_file = Rails.root.join('config/installation_config.yml')
    return unless File.exist?(config_file)
    
    configs = YAML.safe_load(File.read(config_file))
    
    # Identifica quais configs devem estar bloqueadas (locked != false no YAML)
    locked_config_names = configs.select { |c| c['locked'] != false }.map { |c| c['name'] }
    
    # Re-bloqueia apenas as configs que originalmente estavam bloqueadas
    updated_count = InstallationConfig.where(name: locked_config_names).update_all(locked: true)
    
    Rails.logger.info "✓ #{updated_count} configurações foram re-bloqueadas aos valores padrão"
    puts "✓ #{updated_count} configurações foram re-bloqueadas aos valores padrão"
  end
end
