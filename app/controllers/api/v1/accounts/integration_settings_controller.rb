class Api::V1::Accounts::IntegrationSettingsController < Api::V1::Accounts::BaseController
  before_action :check_authorization

  SENSITIVE_KEYS = %w[accessToken apiKey clientSecret refreshToken authToken token].freeze

  # Returns the effective (merged) config — what is actually being used right now
  def show
    effective = IntegrationSettingsService.get_config(Current.account.id, params[:provider])
    setting   = IntegrationSetting.find_by(account_id: Current.account.id, provider: params[:provider])
    render json: {
      provider: params[:provider],
      enabled: setting ? setting.enabled : true,
      config: mask_sensitive(effective),
      has_account_config: setting.present?,
      sources: config_sources(params[:provider], effective)
    }
  end

  # Saves account-level config for the current account
  def update
    setting = IntegrationSetting.find_or_initialize_by(
      account_id: Current.account.id,
      provider: params[:provider]
    )
    incoming = params.require(:config).permit!.to_h.reject { |_, v| v.blank? }
    setting.config  = setting.config_hash.merge(incoming).to_json
    setting.enabled = params.fetch(:enabled, true)
    setting.save!
    render json: {
      provider: params[:provider],
      enabled: setting.enabled,
      config: mask_sensitive(setting.config_hash)
    }
  rescue ActionController::ParameterMissing => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def test_connection
    config = IntegrationSettingsService.get_config(Current.account.id, params[:provider])
    result = IntegrationSettingsService.test_connection(params[:provider], config)
    status = result[:ok] ? :ok : :unprocessable_entity
    render json: result, status: status
  end

  # Admin action: read current ENV vars and persist as global (account_id = nil) config
  def import_from_env
    result = IntegrationSettingsService.import_from_env(params[:provider])
    render json: { provider: params[:provider], imported: result[:imported] }
  end

  private

  def check_authorization
    authorize(IntegrationSetting)
  end

  # Shows which tier (account / global / env) each key is sourced from
  def config_sources(provider, effective_config)
    account_cfg = IntegrationSettingsService.load_db(Current.account.id, provider)
    global_cfg  = IntegrationSettingsService.load_db(nil, provider)
    effective_config.keys.each_with_object({}) do |key, sources|
      sources[key] = if account_cfg.key?(key)  then 'account'
                     elsif global_cfg.key?(key) then 'global'
                     else                            'env'
                     end
    end
  end

  def mask_sensitive(config)
    config.each_with_object({}) do |(key, value), masked|
      masked[key] = if SENSITIVE_KEYS.include?(key) && value.present?
                      "#{value.to_s.first(4)}#{'*' * 20}#{value.to_s.last(3)}"
                    else
                      value
                    end
    end
  end
end
