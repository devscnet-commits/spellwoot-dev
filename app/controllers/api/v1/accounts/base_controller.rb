class Api::V1::Accounts::BaseController < Api::BaseController
  include SwitchLocale
  include EnsureCurrentAccountHelper
  before_action :current_account
  before_action :check_agent_active
  around_action :switch_locale_using_account_locale

  private

  def check_agent_active
    return unless Current.account_user
    return if Current.account_user.active?

    render json: { error: 'Your account has been deactivated.' }, status: :forbidden
  end
end
