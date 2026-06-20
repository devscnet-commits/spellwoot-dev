# History + rollback for an agent's configuration. Listing is read-only; restore re-applies a
# past snapshot and records the rollback as a new version (so history is never lost).
class Api::V1::Accounts::AiAgentVersionsController < Api::V1::Accounts::BaseController
  before_action :set_agent

  def index
    render json: ::Ai::AgentVersion.where(ai_agent_id: @agent.id).recent
  end

  def restore
    version = ::Ai::AgentVersion.find_by(id: params[:id], ai_agent_id: @agent.id)
    return render(json: { error: 'versão não encontrada' }, status: :not_found) if version.nil?

    @agent.update!(version.snapshot.slice(*::Ai::AgentVersion::SNAPSHOT_FIELDS))
    ::Ai::AgentVersion.snapshot!(@agent, note: "Restaurado da v#{version.version_number}")
    render json: @agent
  end

  private

  def set_agent
    @agent = ::Ai::Agent.find_by(id: params[:ai_agent_id], account_id: Current.account.id)
    render(json: { error: 'agente não encontrado' }, status: :not_found) if @agent.nil?
  end
end
