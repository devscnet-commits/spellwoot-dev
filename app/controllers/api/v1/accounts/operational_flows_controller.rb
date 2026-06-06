class Api::V1::Accounts::OperationalFlowsController < Api::V1::Accounts::BaseController
  before_action :fetch_operational_flow, only: [:show, :update, :destroy]
  before_action :check_authorization

  def index
    @operational_flows = Current.account.operational_flows.includes(:reasons)
  end

  def show; end

  def create
    @operational_flow = Current.account.operational_flows.create!(operational_flow_params)
  end

  def update
    @operational_flow.update!(operational_flow_params)
  end

  def destroy
    @operational_flow.destroy!
    head :ok
  end

  private

  def fetch_operational_flow
    @operational_flow = Current.account.operational_flows.find(params[:id])
  end

  def operational_flow_params
    params.require(:operational_flow).permit(
      :name, :require_reason, :active,
      inbox_ids: [],
      reasons_attributes: [:id, :result, :label, :position, :active, :_destroy]
    )
  end
end
