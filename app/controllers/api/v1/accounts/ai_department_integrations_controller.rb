# Integrações tab: lists the account's integrations with an enabled flag for this department,
# and syncs the enabled set. Nested under ai_agents -> ai_departments.
class Api::V1::Accounts::AiDepartmentIntegrationsController < Api::V1::Accounts::BaseController
  before_action :set_department

  def show
    enabled_ids = @department.department_integrations.pluck(:ai_integration_link_id).to_set
    links = ::Ai::IntegrationLink.where(account_id: Current.account.id).order(:name)
    render json: links.map { |link| link.as_json.merge('enabled' => enabled_ids.include?(link.id)) }
  end

  # Body: { integration_link_ids: [1, 2, ...] } — replaces the enabled set.
  def update
    ids = Array(params[:integration_link_ids]).map(&:to_i)
    valid_ids = ::Ai::IntegrationLink.where(account_id: Current.account.id, id: ids).pluck(:id)

    @department.department_integrations.where.not(ai_integration_link_id: valid_ids).delete_all
    existing = @department.department_integrations.pluck(:ai_integration_link_id).to_set
    (valid_ids - existing.to_a).each do |link_id|
      @department.department_integrations.create!(ai_integration_link_id: link_id)
    end
    head :ok
  end

  private

  def set_department
    agent = ::Ai::Agent.find_by(id: params[:ai_agent_id], account_id: Current.account.id)
    @department = agent&.departments&.find_by(id: params[:ai_department_id])
    render(json: { error: 'departamento não encontrado' }, status: :not_found) if @department.nil?
  end
end
