# History + rollback for an agent's "Comportamento" config (the behavior jsonb). Uses the
# polymorphic Ai::Version (versionable = the agent). Restore deep-merges the snapshotted behavior
# keys back into the agent and records the rollback as a new version (so history is never lost).
# Separate from ai_agent_versions (identity fields: name/base_prompt/guardrails/...) — different
# snapshot_fields scope, same versionable record since the fusão Departamento -> Agente (19/08).
# JSON shape matches ai_agent_versions: { id, version_number, note, created_at }.
class Api::V1::Accounts::AiAgentBehaviorVersionsController < Api::V1::Accounts::BaseController
  before_action :set_agent

  def index
    render json: ::Ai::Version.for_record(@agent).recent.map { |version| serialize(version) }
  end

  def restore
    version = ::Ai::Version.for_record(@agent).find_by(id: params[:id])
    return render(json: { error: 'versão não encontrada' }, status: :not_found) if version.nil?

    fields = Api::V1::Accounts::AiAgentsController::BEHAVIOR_FIELDS
    # PRÉ-SNAPSHOT: captura o estado ATUAL antes de sobrescrever (mudanças por console não geram versão) —
    # torna o restore REVERSÍVEL. Ver ai_playbook_versions_controller.
    ::Ai::Version.snapshot!(@agent, snapshot_fields: fields, note: 'Estado antes da restauração')
    version.restore!(fields)
    new_version = ::Ai::Version.snapshot!(@agent, snapshot_fields: fields,
                                                   note: "Restaurado da v#{version.version_number}")
    render json: serialize(new_version)
  end

  private

  def set_agent
    @agent = ::Ai::Agent.find_by(id: params[:ai_agent_id], account_id: Current.account.id)
    render(json: { error: 'agente não encontrado' }, status: :not_found) if @agent.nil?
  end

  def serialize(version)
    version.slice(:id, :version_number, :note, :created_at)
  end
end
