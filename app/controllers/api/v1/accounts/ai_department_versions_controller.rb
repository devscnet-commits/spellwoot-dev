# History + rollback for a department's "Comportamento" config (the behavior jsonb). Uses the
# polymorphic Ai::Version (versionable = the department). Restore deep-merges the snapshotted behavior
# keys back into the department and records the rollback as a new version (so history is never lost).
# JSON shape matches ai_agent_versions: { id, version_number, note, created_at }.
class Api::V1::Accounts::AiDepartmentVersionsController < Api::V1::Accounts::BaseController
  before_action :set_department

  def index
    render json: ::Ai::Version.for_record(@department).recent.map { |version| serialize(version) }
  end

  def restore
    version = ::Ai::Version.for_record(@department).find_by(id: params[:id])
    return render(json: { error: 'versão não encontrada' }, status: :not_found) if version.nil?

    fields = Api::V1::Accounts::AiDepartmentsController::DEPARTMENT_BEHAVIOR_FIELDS
    version.restore!(fields)
    new_version = ::Ai::Version.snapshot!(@department, snapshot_fields: fields,
                                                       note: "Restaurado da v#{version.version_number}")
    render json: serialize(new_version)
  end

  private

  def set_department
    agent = ::Ai::Agent.find_by(id: params[:ai_agent_id], account_id: Current.account.id)
    @department = agent&.departments&.find_by(id: params[:ai_department_id])
    render(json: { error: 'departamento não encontrado' }, status: :not_found) if @department.nil?
  end

  def serialize(version)
    version.slice(:id, :version_number, :note, :created_at)
  end
end
