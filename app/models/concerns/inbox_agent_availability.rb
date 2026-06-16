module InboxAgentAvailability
  extend ActiveSupport::Concern

  def available_agents
    online_agent_ids = fetch_online_agent_ids
    return inbox_members.none if online_agent_ids.empty?

    inbox_members
      .where(eligible_for_assignment: true)
      .joins(:user)
      .where(users: { id: online_agent_ids })
      .joins("INNER JOIN account_users ON account_users.user_id = users.id AND account_users.account_id = #{account_id.to_i}")
      .where(account_users: { active: true, receives_assignments: true })
      .includes(:user)
  end

  def member_ids_with_assignment_capacity
    member_ids
  end

  private

  def fetch_online_agent_ids
    OnlineStatusTracker.get_available_users(account_id)
                       .select { |_key, value| value.eql?('online') }
                       .keys
                       .map(&:to_i)
  end
end

InboxAgentAvailability.prepend_mod_with('InboxAgentAvailability')
