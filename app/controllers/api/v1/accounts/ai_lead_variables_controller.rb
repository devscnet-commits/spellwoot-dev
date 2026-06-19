# CRUD for a department's lead variables (Instruções tab). Nested under ai_agents -> ai_departments.
class Api::V1::Accounts::AiLeadVariablesController < Api::V1::Accounts::BaseController
  before_action :set_department
  before_action :set_variable, only: %i[update destroy]

  def index
    render json: @department.lead_variables.order(:position, :id)
  end

  def create
    variable = @department.lead_variables.new(variable_params.merge(account_id: Current.account.id))
    save_and_render(variable, :created)
  end

  def update
    @variable.assign_attributes(variable_params)
    save_and_render(@variable, :ok)
  end

  def destroy
    @variable.destroy!
    head :no_content
  end

  private

  def set_department
    agent = ::Ai::Agent.find_by(id: params[:ai_agent_id], account_id: Current.account.id)
    @department = agent&.departments&.find_by(id: params[:ai_department_id])
    render(json: { error: 'departamento não encontrado' }, status: :not_found) if @department.nil?
  end

  def set_variable
    @variable = @department.lead_variables.find_by(id: params[:id])
    render(json: { error: 'variável não encontrada' }, status: :not_found) if @variable.nil?
  end

  def variable_params
    permitted = params.require(:ai_lead_variable).permit(
      :name, :description, :var_type, :visible_in_first_chat, :position
    )
    raw_values = params.dig(:ai_lead_variable, :values)
    permitted[:values] = Array(raw_values) if raw_values
    permitted
  end

  def save_and_render(variable, ok_status)
    if variable.save
      render json: variable, status: ok_status
    else
      render json: { errors: variable.errors.full_messages }, status: :unprocessable_entity
    end
  end
end
