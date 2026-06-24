# CRUD for a department's Tools. A Tool wraps a capability (internal) or an integration (external).
# Nested under ai_agents -> ai_departments.
class Api::V1::Accounts::AiToolsController < Api::V1::Accounts::BaseController
  before_action :set_department
  before_action :set_tool, only: %i[update destroy]

  def index
    render json: @department.tools.order(:id)
  end

  def create
    tool = @department.tools.new(tool_params.merge(account_id: Current.account.id))
    tool.assign_attributes(schema_params)
    save_and_render(tool, :created)
  end

  def update
    @tool.assign_attributes(tool_params.merge(schema_params))
    save_and_render(@tool, :ok)
  end

  def destroy
    @tool.destroy!
    head :no_content
  end

  private

  def set_department
    agent = ::Ai::Agent.find_by(id: params[:ai_agent_id], account_id: Current.account.id)
    @department = agent&.departments&.find_by(id: params[:ai_department_id])
    render(json: { error: 'departamento não encontrado' }, status: :not_found) if @department.nil?
  end

  def set_tool
    @tool = @department.tools.find_by(id: params[:id])
    render(json: { error: 'ferramenta não encontrada' }, status: :not_found) if @tool.nil?
  end

  def tool_params
    params.require(:ai_tool).permit(:name, :description, :implementation_type, :capability_key,
                                    :integration_link_id, :governance, :status)
  end

  def schema_params
    source = params[:ai_tool] || {}
    value = source[:input_schema]
    return {} if value.nil?

    { input_schema: value.respond_to?(:permit!) ? value.permit!.to_h : value }
  end

  def save_and_render(tool, ok_status)
    if tool.save
      render json: tool, status: ok_status
    else
      render json: { errors: tool.errors.full_messages }, status: :unprocessable_entity
    end
  end
end
