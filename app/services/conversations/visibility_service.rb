# Single source of truth for "which conversations can this viewer see" (spec part 2, §11).
# Consumed by the conversation list, the tab counters, and the reports scope so the numbers can
# never diverge between screens.
#
# Scope is anchored on the viewer's role:
#   account -> everything (administrators)
#   inbox   -> conversations in the viewer's member inboxes
#   team    -> conversations assigned to members of the viewer's teams
#   own     -> conversations assigned to the viewer
#   <nil>   -> legacy: inbox ∪ elevated-team (preserves pre-rollout behavior for roles without
#              an explicit visibility_scope)
#
# A participant grant always makes a conversation visible, regardless of scope. The unassigned
# queue of the viewer's inboxes is added for own/team scopes when can_view_unassigned_queue is set.
class Conversations::VisibilityService
  def initialize(conversations, user, account)
    @conversations = conversations
    @user = user
    @account = account
  end

  def perform
    return @conversations if scope == 'account'

    relation = base_scope
    relation = relation.or(unassigned_queue_scope) if view_unassigned_queue?
    relation.or(participating_scope)
  end

  private

  def base_scope
    case scope
    when 'inbox' then @conversations.where(inbox_id: accessible_inbox_ids)
    when 'team' then @conversations.where(assignee_id: team_member_user_ids)
    when 'own' then @conversations.where(assignee_id: @user.id)
    else legacy_scope
    end
  end

  # Historical visibility for roles/users without an explicit visibility_scope.
  def legacy_scope
    inbox_scope = @conversations.where(inbox_id: accessible_inbox_ids)
    return inbox_scope if elevated_team_ids.empty?

    inbox_scope.or(@conversations.where(team_id: elevated_team_ids))
  end

  def unassigned_queue_scope
    @conversations.where(assignee_id: nil, inbox_id: accessible_inbox_ids)
  end

  def participating_scope
    @conversations.where(
      id: ConversationParticipant.where(user_id: @user.id, account_id: @account.id).select(:conversation_id)
    )
  end

  def scope
    return 'account' if account_user&.administrator?

    custom_role&.visibility_scope.presence || 'legacy'
  end

  # Only meaningful once a role anchors on own/team (inbox/account already see the queue).
  def view_unassigned_queue?
    cr = custom_role
    cr&.visibility_scope.present? && cr.can_view_unassigned_queue
  end

  def accessible_inbox_ids
    @accessible_inbox_ids ||= @user.inboxes.where(account_id: @account.id).pluck(:id)
  end

  def team_member_user_ids
    team_ids = TeamMember.joins(:team)
                         .where(user_id: @user.id, teams: { account_id: @account.id })
                         .pluck(:team_id)
    TeamMember.where(team_id: team_ids).distinct.pluck(:user_id)
  end

  def elevated_team_ids
    @elevated_team_ids ||= TeamMember.joins(:team)
                                     .where(user_id: @user.id, teams: { account_id: @account.id })
                                     .with_elevated_access
                                     .pluck(:team_id)
  end

  def account_user
    @account_user ||= AccountUser.find_by(account_id: @account.id, user_id: @user.id)
  end

  def custom_role
    return @custom_role if defined?(@custom_role)

    @custom_role = account_user.respond_to?(:custom_role) ? account_user&.custom_role : nil
  end
end
