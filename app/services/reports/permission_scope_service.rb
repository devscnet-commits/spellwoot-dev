module Reports
  # Scopes reporting data based on the current user's role.
  #
  #   Admin       → full account data (no restriction)
  #   Coordinator/Manager → data for teams where they hold an elevated role
  #   Agent (member only) → their own data only
  #
  class PermissionScopeService
    def initialize(account_user)
      @account_user = account_user
      @user_id      = account_user.user_id
      @account_id   = account_user.account_id
    end

    # ── ActiveRecord scope helpers ──────────────────────────────────────────

    def scope_reporting_events(scope)
      return scope if admin?
      return scope.where(user_id: @user_id) if agent_only?

      scope.where(team_id: accessible_team_ids)
    end

    # Conversation reports go through the same visibility source as the list and tab counters,
    # so the numbers can never diverge between screens (spec part 2, §13).
    def scope_conversations(scope)
      Conversations::VisibilityService.new(scope, @account_user.user, @account_user.account).perform
    end

    # Scope account_users to only those visible to the current user.
    def scope_account_users(scope)
      return scope if admin?
      return scope.where(user_id: @user_id) if agent_only?

      visible_user_ids = TeamMember.where(team_id: accessible_team_ids).pluck(:user_id)
      scope.where(user_id: visible_user_ids)
    end

    # Scope teams to only those accessible to the current user.
    def scope_teams(scope)
      return scope if admin?
      return scope.none if agent_only?

      scope.where(id: accessible_team_ids)
    end

    # Scope inboxes to those relevant to the current user's accessible data.
    def scope_inboxes(scope)
      return scope if admin?

      if agent_only?
        inbox_ids = InboxMember.where(user_id: @user_id).pluck(:inbox_id)
        return scope.where(id: inbox_ids)
      end

      inbox_ids = Conversation.where(account_id: @account_id, team_id: accessible_team_ids)
                              .distinct.pluck(:inbox_id)
      scope.where(id: inbox_ids)
    end

    # ── Predicate helpers ───────────────────────────────────────────────────

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

    def current_user_id
      @user_id
    end
  end
end
