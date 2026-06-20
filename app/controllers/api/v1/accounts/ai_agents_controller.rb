# CRUD for AI Agents (the "Agentes IA" config). Scoped to the current account; ai_* domain only.
class Api::V1::Accounts::AiAgentsController < Api::V1::Accounts::BaseController
  before_action :set_agent, only: %i[show update destroy test]

  def index
    agents = ::Ai::Agent.where(account_id: Current.account.id)
                        .includes(:operation_profile, :departments, :agent_inboxes)
                        .order(:id)
    render json: agents.map { |agent| serialize_list(agent) }
  end

  def show
    render json: @agent
  end

  def create
    agent = ::Ai::Agent.new(agent_params.merge(account_id: Current.account.id))
    if agent.save
      ::Ai::AgentVersion.snapshot!(agent)
      render json: agent, status: :created
    else
      render json: { errors: agent.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def update
    if @agent.update(agent_params)
      ::Ai::AgentVersion.snapshot!(@agent)
      render json: @agent
    else
      render json: { errors: @agent.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def destroy
    @agent.destroy!
    head :no_content
  end

  # Teste tab: dry-run a message against the agent and return the decision breakdown.
  def test
    render json: ::Ai::Tester.run(agent: @agent, message: params[:message].to_s, department_id: params[:department_id])
  end

  private

  def set_agent
    @agent = ::Ai::Agent.find_by(id: params[:id], account_id: Current.account.id)
    render(json: { error: 'não encontrado' }, status: :not_found) if @agent.nil?
  end

  def agent_params
    params.require(:ai_agent).permit(
      :name, :stage, :status, :category, :assistant_name, :assistant_avatar, :assistant_description,
      :assistant_personality, :assistant_language, :assistant_voice, :base_prompt, :guardrails,
      :ai_operation_profile_id, :company_name, :site, :version, :identify_as
    )
  end

  # List row: enrich with the department count, the profile name and whether the agent has any
  # live/shadow binding, so the table can show Tipo / Perfil / Departamentos / Status at a glance.
  def serialize_list(agent)
    bindings = agent.agent_inboxes.select(&:active)
    agent.as_json.merge(
      'departments_count' => agent.departments.size,
      'operation_profile_name' => agent.operation_profile&.name,
      'has_live' => bindings.any? { |b| b.mode == 'live' },
      'has_shadow' => bindings.any? { |b| b.mode == 'shadow' }
    )
  end
end
