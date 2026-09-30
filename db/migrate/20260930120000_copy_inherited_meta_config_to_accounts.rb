# A config da Meta (Pixel/Token/Test Event Code) deixou de herdar do global/ENV: cada conta só usa o que ela
# mesma cadastrou (IntegrationSettingsService::SHARED_PROVIDERS). Conta que JÁ enviava conversões herdando a
# config da plataforma (interruptor da API de Conversões ligado, sem Pixel/Token próprios) pararia em silêncio.
# Para essas, a config herdada vira config da conta — o envio continua igual, agora com o selo "Esta conta", e
# o admin troca pelo Pixel do cliente quando quiser. Contas com o interruptor desligado ficam sem config.
class CopyInheritedMetaConfigToAccounts < ActiveRecord::Migration[7.1]
  def up
    inherited = IntegrationSettingsService.load_env('meta').merge(IntegrationSettingsService.load_db(nil, 'meta'))
    return if inherited['pixelId'].blank? || inherited['accessToken'].blank?

    Account.find_each do |account|
      next unless account.settings&.dig('meta_conversion_settings', 'enabled') == true

      copy_inherited!(account, inherited)
    end
  end

  def down; end

  private

  def copy_inherited!(account, inherited)
    setting = IntegrationSetting.find_or_initialize_by(account_id: account.id, provider: 'meta')
    # Linha desativada pela conta: antes já não enviava nada (get_config devolvia {}).
    return if setting.persisted? && !setting.enabled?

    own = setting.config_hash.reject { |_, v| v.blank? }
    return if own['pixelId'].present? && own['accessToken'].present?

    setting.update!(config: inherited.merge(own).to_json)
    say "conta #{account.id}: config da Meta herdada copiada para a conta"
  end
end
