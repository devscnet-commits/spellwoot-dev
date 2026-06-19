# Caixas tab section (inside the department "Atendimento"): which of the agent's inboxes this
# department handles. Consumed by Ai::DepartmentResolver to route a message to a department.
class Api::V1::Accounts::AiDepartmentInboxesController < Api::V1::Accounts::BaseController
  before_action :set_department

  def show
    enabled_ids = @department.department_inboxes.pluck(:inbox_id).to_set
    inboxes = agent_inboxes
    render json: inboxes.map { |inbox|
      { 'inbox_id' => inbox.id, 'name' => inbox.name, 'channel_type' => inbox.channel_type,
        'enabled' => enabled_ids.include?(inbox.id) }
    }
  end

  # Body: { inbox_ids: [1, 2, ...] } — replaces the mapped set (only the agent's bound inboxes).
  def update
    valid_ids = agent_inboxes.map(&:id) & Array(params[:inbox_ids]).map(&:to_i)

    @department.department_inboxes.where.not(inbox_id: valid_ids).delete_all
    existing = @department.department_inboxes.pluck(:inbox_id).to_set
    (valid_ids - existing.to_a).each { |inbox_id| @department.department_inboxes.create!(inbox_id: inbox_id) }
    head :ok
  end

  private

  def set_department
    @agent = ::Ai::Agent.find_by(id: params[:ai_agent_id], account_id: Current.account.id)
    @department = @agent&.departments&.find_by(id: params[:ai_department_id])
    render(json: { error: 'departamento não encontrado' }, status: :not_found) if @department.nil?
  end

  # Only inboxes the agent is bound to are mappable — you route among the caixas it already attends.
  def agent_inboxes
    ids = @agent.agent_inboxes.pluck(:inbox_id)
    Current.account.inboxes.where(id: ids).order(:name)
  end
end
