# CRUD for AI Agents (the "Agentes IA" config). Scoped to the current account; ai_* domain only.
class Api::V1::Accounts::AiAgentsController < Api::V1::Accounts::BaseController
  before_action :set_agent, only: %i[show update destroy test]

  def index
    render json: ::Ai::Agent.where(account_id: Current.account.id).order(:id)
  end

  def show
    render json: @agent
  end

  def create
    agent = ::Ai::Agent.new(agent_params.merge(account_id: Current.account.id))
    if agent.save
      render json: agent, status: :created
    else
      render json: { errors: agent.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def update
    if @agent.update(agent_params)
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
      :name, :stage, :status, :assistant_name, :assistant_avatar, :assistant_description,
      :assistant_personality, :assistant_language, :assistant_voice, :base_prompt, :guardrails,
      :ai_operation_profile_id, :company_name, :site, :version, :identify_as
    )
  end
end
