# History + rollback for a department's playbook. Restore re-applies a past snapshot to the
# active playbook and records the rollback as a new version.
class Api::V1::Accounts::AiPlaybookVersionsController < Api::V1::Accounts::BaseController
  before_action :set_department

  def index
    playbook = @department.playbook
    render json: playbook ? ::Ai::Version.for_record(playbook).recent.map { |version| serialize(version) } : []
  end

  def restore
    playbook = @department.playbook
    version = playbook && ::Ai::Version.for_record(playbook).find_by(id: params[:id])
    return render(json: { error: 'versão não encontrada' }, status: :not_found) if version.nil?

    # PRÉ-SNAPSHOT: captura o estado ATUAL antes de sobrescrever. snapshot! só roda no update do controller,
    # então mudanças por CONSOLE (foi assim que on_complete/knowledge/list_all entraram) NÃO geram versão —
    # sem isto, restaurar qualquer versão anterior as apagaria SEM histórico para recuperar. Com a nota,
    # sempre grava (não deduplica): torna o restore REVERSÍVEL.
    ::Ai::Version.snapshot!(playbook, snapshot_fields: ::Ai::Playbook::SNAPSHOT_FIELDS,
                                      note: 'Estado antes da restauração')
    # Restore é ROLLBACK, não escrita nova: isenta a validação H6 (on_complete na whitelist). Um estado JÁ
    # persistido não deve ser barrado pela whitelist de HOJE — senão o usuário não volta atrás porque a
    # config mudou depois. O flag vai no objeto que o restore! atualiza (version.versionable).
    version.versionable.restoring = true if version.versionable.respond_to?(:restoring=)
    version.restore!(::Ai::Playbook::SNAPSHOT_FIELDS)
    ::Ai::Version.snapshot!(playbook, snapshot_fields: ::Ai::Playbook::SNAPSHOT_FIELDS,
                                      note: "Restaurado da v#{version.version_number}")
    render json: playbook
  end

  private

  def set_department
    agent = ::Ai::Agent.find_by(id: params[:ai_agent_id], account_id: Current.account.id)
    @department = agent&.departments&.find_by(id: params[:ai_department_id])
    render(json: { error: 'departamento não encontrado' }, status: :not_found) if @department.nil?
  end

  # Mesma shape enxuta do ai_department_versions ({ id, version_number, note, created_at }).
  def serialize(version)
    version.slice(:id, :version_number, :note, :created_at)
  end
end
