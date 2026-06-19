# Read-only list of operation profiles for the agent form dropdown.
class Api::V1::Accounts::AiOperationProfilesController < Api::V1::Accounts::BaseController
  def index
    render json: ::Ai::OperationProfile.where(account_id: Current.account.id).order(:name)
  end
end
