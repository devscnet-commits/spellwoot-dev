# History + rollback for an agent's configuration. Listing is read-only; restore re-applies a
# past snapshot and records the rollback as a new version (so history is never lost).
class Api::V1::Accounts::AiAgentVersionsController < Api::V1::Accounts::BaseController
  before_action :set_agent

  def index
    render json: ::Ai::Version.for_record(@agent).recent.map { |version| serialize(version) }
  end

  def restore
    version = ::Ai::Version.for_record(@agent).find_by(id: params[:id])
    return render(json: { error: 'versão não encontrada' }, status: :not_found) if version.nil?

    version.restore!(::Ai::Agent::SNAPSHOT_FIELDS)
    ::Ai::Version.snapshot!(@agent, snapshot_fields: ::Ai::Agent::SNAPSHOT_FIELDS,
                                    note: "Restaurado da v#{version.version_number}")
    render json: @agent
  end

  private

  def set_agent
    @agent = ::Ai::Agent.find_by(id: params[:ai_agent_id], account_id: Current.account.id)
    render(json: { error: 'agente não encontrado' }, status: :not_found) if @agent.nil?
  end

  # Mesma shape enxuta do ai_department_versions ({ id, version_number, note, created_at }); o front
  # (AiVersionHistory.vue) só usa esses campos e não deve receber o snapshot/versionable/account_id.
  def serialize(version)
    version.slice(:id, :version_number, :note, :created_at)
  end
end
