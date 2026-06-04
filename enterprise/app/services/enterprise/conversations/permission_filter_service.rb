module Enterprise::Conversations::PermissionFilterService
  def perform
    return filter_by_permissions(permissions) if user_has_custom_role?

    super
  end

  private

  def user_has_custom_role?
    user_role == 'agent' && account_user&.custom_role_id.present?
  end

  def permissions
    account_user&.permissions || []
  end

  def filter_by_permissions(permissions)
    base = scoped_accessible_conversations
    if permissions.include?('conversation_manage')
      base
    elsif permissions.include?('conversation_unassigned_manage')
      mine = base.assigned_to(user)
      unassigned = base.unassigned
      Conversation.from("(#{mine.to_sql} UNION #{unassigned.to_sql}) as conversations")
                  .where(account_id: account.id)
    elsif permissions.include?('conversation_participating_manage')
      base.assigned_to(user)
    else
      Conversation.none
    end
  end

  def scoped_accessible_conversations
    base = accessible_conversations
    return base if custom_role_scope_type == 'all'

    base.where(inbox_id: scoped_inbox_ids)
  end

  def custom_role_scope_type
    account_user&.custom_role&.scope_type || 'all'
  end

  def scoped_inbox_ids
    @scoped_inbox_ids ||= account_user.custom_role.scoped_inboxes(account).map(&:id)
  end
end
