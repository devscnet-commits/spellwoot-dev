class Conversations::PermissionFilterService
  attr_reader :conversations, :user, :account

  def initialize(conversations, user, account)
    @conversations = conversations
    @user = user
    @account = account
  end

  def perform
    return conversations if user_role == 'administrator'

    accessible_conversations
  end

  private

  def accessible_conversations
    inbox_scope = conversations.where(inbox: user.inboxes.where(account_id: account.id))
    return inbox_scope if elevated_team_ids.empty?

    inbox_scope.or(conversations.where(team_id: elevated_team_ids))
  end

  # Teams where the user has coordinator or manager role — grants visibility of all
  # conversations belonging to those teams regardless of inbox membership.
  def elevated_team_ids
    @elevated_team_ids ||= TeamMember
                           .joins(:team)
                           .where(user_id: user.id, teams: { account_id: account.id })
                           .with_elevated_access
                           .pluck(:team_id)
  end

  def account_user
    @account_user ||= AccountUser.find_by(account_id: account.id, user_id: user.id)
  end

  def user_role
    account_user&.role
  end
end

Conversations::PermissionFilterService.prepend_mod_with('Conversations::PermissionFilterService')
