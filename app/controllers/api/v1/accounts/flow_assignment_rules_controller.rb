class Api::V1::Accounts::FlowAssignmentRulesController < Api::V1::Accounts::BaseController
  before_action :fetch_rule, only: [:update, :destroy]
  before_action :check_authorization

  def index
    @rules = Current.account.flow_assignment_rules.ordered
  end

  def create
    @rule = Current.account.flow_assignment_rules.create!(rule_params)
  end

  def update
    @rule.update!(rule_params)
  end

  def destroy
    @rule.destroy!
    head :ok
  end

  private

  def fetch_rule
    @rule = Current.account.flow_assignment_rules.find(params[:id])
  end

  def rule_params
    params.require(:flow_assignment_rule).permit(
      :operational_flow_id, :priority, :is_default,
      predicate: {}
    )
  end
end
