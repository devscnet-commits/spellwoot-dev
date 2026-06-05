module Reports
  # Scopes reporting data based on the current user's role.
  #
  #   Admin       → full account data (no restriction)
  #   Coordinator/Manager → data for teams where they hold an elevated role
  #   Agent (member only) → their own data only (user_id = current user)
  #
  class PermissionScopeService
    def initialize(account_user)
      @account_user = account_user
      @user_id      = account_user.user_id
      @account_id   = account_user.account_id
    end

    def scope_reporting_events(scope)
      return scope if admin?
      return scope.where(user_id: @user_id) if agent_only?

      scope.where(team_id: accessible_team_ids)
    end

    def scope_conversations(scope)
      return scope if admin?
      return scope.where(assignee_id: @user_id) if agent_only?

      scope.where(team_id: accessible_team_ids)
    end

    def accessible_team_ids
      @accessible_team_ids ||= TeamMember
                               .joins(:team)
                               .where(user_id: @user_id, teams: { account_id: @account_id })
                               .with_elevated_access
                               .pluck(:team_id)
    end

    def admin?
      @account_user.administrator?
    end

    def agent_only?
      !admin? && accessible_team_ids.empty?
    end
  end
end
