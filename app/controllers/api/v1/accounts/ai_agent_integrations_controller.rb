# Integrações tab: lists the account's integrations with an enabled flag for this agent,
# and syncs the enabled set. Nested under ai_agents.
class Api::V1::Accounts::AiAgentIntegrationsController < Api::V1::Accounts::BaseController
  before_action :set_agent

  def show
    enabled_ids = @agent.department_integrations.pluck(:ai_integration_link_id).to_set
    links = ::Ai::IntegrationLink.where(account_id: Current.account.id).order(:name)
    render json: links.map { |link| link.as_json.merge('enabled' => enabled_ids.include?(link.id)) }
  end

  # Body: { integration_link_ids: [1, 2, ...] } — replaces the enabled set.
  def update
    ids = Array(params[:integration_link_ids]).map(&:to_i)
    valid_ids = ::Ai::IntegrationLink.where(account_id: Current.account.id, id: ids).pluck(:id)

    @agent.department_integrations.where.not(ai_integration_link_id: valid_ids).delete_all
    existing = @agent.department_integrations.pluck(:ai_integration_link_id).to_set
    (valid_ids - existing.to_a).each do |link_id|
      @agent.department_integrations.create!(ai_integration_link_id: link_id)
    end
    head :ok
  end

  private

  def set_agent
    @agent = ::Ai::Agent.find_by(id: params[:ai_agent_id], account_id: Current.account.id)
    render(json: { error: 'agente não encontrado' }, status: :not_found) if @agent.nil?
  end
end
