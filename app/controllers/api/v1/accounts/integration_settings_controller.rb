class Api::V1::Accounts::IntegrationSettingsController < Api::V1::Accounts::BaseController
  before_action :check_authorization

  SENSITIVE_KEYS = %w[accessToken apiKey clientSecret refreshToken authToken token].freeze

  def show
    setting = IntegrationSetting.find_by(account_id: Current.account.id, provider: params[:provider])
    config = setting ? JSON.parse(setting.config.presence || '{}') : {}
    render json: { provider: params[:provider], config: mask_sensitive(config) }
  end

  def update
    setting = IntegrationSetting.find_or_initialize_by(
      account_id: Current.account.id,
      provider: params[:provider]
    )
    setting.config = params.require(:config).permit!.to_h.to_json
    setting.save!
    config = JSON.parse(setting.config)
    render json: { provider: params[:provider], config: mask_sensitive(config) }
  rescue ActionController::ParameterMissing => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def check_authorization
    authorize(IntegrationSetting)
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
