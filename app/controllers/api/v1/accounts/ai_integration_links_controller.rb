# Read-only list of external integration connectors for the Tool form dropdown.
class Api::V1::Accounts::AiIntegrationLinksController < Api::V1::Accounts::BaseController
  def index
    render json: ::Ai::IntegrationLink.where(account_id: Current.account.id).order(:name)
  end
end
