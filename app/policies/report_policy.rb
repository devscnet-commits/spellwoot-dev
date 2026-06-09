class ReportPolicy < ApplicationPolicy
  def view?
    @account_user.administrator? || elevated_team_member? || active_agent?
  end

  private

  def elevated_team_member?
    TeamMember.joins(:team)
              .where(user_id: @account_user.user_id, teams: { account_id: @account_user.account_id })
              .with_elevated_access
              .exists?
  end

  def active_agent?
    @account_user.active?
  end
end

ReportPolicy.prepend_mod_with('ReportPolicy')
