class ReportPolicy < ApplicationPolicy
  # Relatórios: administrador (e coordenador/gerente de time, com o escopo do Reports::PermissionScopeService).
  # Agente comum não vê — a tela já exigia administrator/report_manage, mas a API liberava qualquer agente ativo.
  def view?
    @account_user.administrator? || elevated_team_member?
  end

  private

  def elevated_team_member?
    TeamMember.joins(:team)
              .where(user_id: @account_user.user_id, teams: { account_id: @account_user.account_id })
              .with_elevated_access
              .exists?
  end
end

ReportPolicy.prepend_mod_with('ReportPolicy')
