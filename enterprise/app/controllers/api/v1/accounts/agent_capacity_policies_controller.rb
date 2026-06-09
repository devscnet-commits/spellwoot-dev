class Api::V1::Accounts::AgentCapacityPoliciesController < Api::V1::Accounts::EnterpriseAccountsController
  before_action :check_authorization
  before_action :fetch_policy, only: [:show, :update, :destroy]

  def index
    @agent_capacity_policies = Current.account.agent_capacity_policies
  end

  def show; end

  def create
    ActiveRecord::Base.transaction do
      @agent_capacity_policy = Current.account.agent_capacity_policies.create!(permitted_params)
      create_inbox_limits
      assign_agents
    end
  end

  def update
    @agent_capacity_policy.update!(permitted_params)
  end

  def destroy
    @agent_capacity_policy.destroy!
    head :ok
  end

  private

  def create_inbox_limits
    return unless params[:inbox_limits].present?

    params.permit(inbox_limits: [:inbox_id, :conversation_limit])[:inbox_limits]&.each do |limit|
      @agent_capacity_policy.inbox_capacity_limits.create!(
        inbox_id: limit[:inbox_id],
        conversation_limit: limit[:conversation_limit].to_i
      )
    end
  end

  def assign_agents
    return unless params[:agent_ids].present?

    params[:agent_ids].each do |agent_id|
      account_user = Current.account.account_users.find_by(user_id: agent_id)
      account_user&.update!(agent_capacity_policy: @agent_capacity_policy)
    end
  end

  def permitted_params
    params.require(:agent_capacity_policy).permit(
      :name,
      :description,
      exclusion_rules: [:exclude_older_than_hours, { excluded_labels: [] }]
    )
  end

  def fetch_policy
    @agent_capacity_policy = Current.account.agent_capacity_policies.find(params[:id])
  end
end
