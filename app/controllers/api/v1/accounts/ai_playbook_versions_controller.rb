# History + rollback for a department's playbook. Restore re-applies a past snapshot to the
# active playbook and records the rollback as a new version.
class Api::V1::Accounts::AiPlaybookVersionsController < Api::V1::Accounts::BaseController
  before_action :set_department

  def index
    render json: ::Ai::PlaybookVersion.where(ai_department_id: @department.id).recent
  end

  def restore
    version = ::Ai::PlaybookVersion.find_by(id: params[:id], ai_department_id: @department.id)
    return render(json: { error: 'versão não encontrada' }, status: :not_found) if version.nil?

    playbook = @department.playbook || @department.build_playbook(active: true)
    playbook.update!(version.snapshot.slice(*::Ai::PlaybookVersion::SNAPSHOT_FIELDS))
    ::Ai::PlaybookVersion.snapshot!(playbook, note: "Restaurado da v#{version.version_number}")
    render json: playbook
  end

  private

  def set_department
    agent = ::Ai::Agent.find_by(id: params[:ai_agent_id], account_id: Current.account.id)
    @department = agent&.departments&.find_by(id: params[:ai_department_id])
    render(json: { error: 'departamento não encontrado' }, status: :not_found) if @department.nil?
  end
end
