class AutoAssignment::AssignmentService
  pattr_initialize [:inbox!]

  def perform_bulk_assignment(limit: 100)
    return 0 unless inbox.auto_assignment_v2_enabled?
    return 0 unless inbox.enable_auto_assignment?
    # Skip auto-assignment outside business hours when working_hours_enabled.
    # The periodic job triggers this path independently of AutoAssignmentHandler,
    # so the guard must live here too.
    return 0 if inbox.out_of_office?

    assigned_count = 0

    unassigned_conversations(limit).each do |conversation|
      assigned_count += 1 if perform_for_conversation(conversation)
    end

    assigned_count
  end

  # Assign a single already-known conversation immediately, applying the same policy as
  # bulk assignment (team filter, fair distribution limit, capacity, balanced/round-robin).
  # Unlike perform_bulk_assignment, this doesn't require conversation.status == 'open' --
  # used when an external integration routes a conversation to a team, which can still be
  # pending (e.g. a bot-captured lead) and should reach a human right away regardless.
  def assign_conversation_now(conversation)
    return false if conversation.assignee_id.present?

    assigned = with_assignment_lock { assign_available_agent(conversation) }
    # A burst of leads landing on the same inbox at nearly the same instant (the normal
    # pattern for paid-ads traffic) means most of them lose the single-shot Redis lock
    # (Redis::LockManager#lock does one SET NX, no wait/retry) and silently give up here --
    # confirmed live on 04/09: several conversations sat with a team but no agent for minutes,
    # until the periodic sweep (AutoAssignment::PeriodicAssignmentJob) eventually caught them.
    # Retry through the same bulk path right away instead of waiting for that next cycle.
    AutoAssignment::AssignmentJob.perform_later(inbox_id: inbox.id) unless assigned
    assigned
  end

  private

  ASSIGNMENT_LOCK_TIMEOUT = 5.seconds

  # find_available_agent (rate-limit check) and assign_conversation (rate-limit tracking write) are
  # two separate Redis round trips (see AutoAssignment::RateLimiter) — not atomic on their own. Without
  # this lock, the periodic AssignmentJob and a real-time AI handoff (Ai::HandoffCoordinator) can both
  # read "agent is under fair_distribution_limit" before either writes its tracking key, so the agent
  # ends up over the configured limit. The lock is per-inbox and held only for one conversation at a
  # time, so it doesn't serialize unrelated inboxes or hold up the whole bulk run.
  def perform_for_conversation(conversation)
    return false unless assignable?(conversation)

    with_assignment_lock { assign_available_agent(conversation) }
  end

  def assign_available_agent(conversation)
    agent = find_available_agent(conversation)
    return false unless agent

    assign_conversation(conversation, agent)
  end

  def with_assignment_lock
    lock_manager = Redis::LockManager.new
    key = format(Redis::RedisKeys::ASSIGNMENT_MUTEX, inbox_id: inbox.id)
    return false unless lock_manager.lock(key, ASSIGNMENT_LOCK_TIMEOUT)

    begin
      yield
    ensure
      lock_manager.unlock(key)
    end
  end

  def assignable?(conversation)
    return false if conversation.assignee_id.present?

    conversation.status == 'open' ||
      (conversation.status == 'pending' && conversation.team_id.present?)
  end

  # Open conversations, plus team-routed ones still sitting in `pending`. AutoAssignmentHandler
  # assigns those the moment the team is set, but that single attempt is all they ever got: if
  # no agent was available right then (all over the limit, none online), nothing retried them
  # because this scan was open-only. Pending conversations *without* a team stay out — those
  # still belong to the bot.
  def assignable_scope
    unassigned = inbox.conversations.unassigned
    unassigned.open.or(unassigned.pending.where.not(team_id: nil))
  end

  def unassigned_conversations(limit)
    scope = assignable_scope

    # Apply conversation priority using assignment policy if available
    policy = inbox.assignment_policy
    scope = if policy&.longest_waiting?
              scope.reorder(last_activity_at: :asc, created_at: :asc)
            else
              scope.reorder(created_at: :asc)
            end

    scope.limit(limit)
  end

  def find_available_agent(conversation = nil)
    eligible_agents = filter_agents_by_team(inbox.available_agents, conversation)
    return nil if eligible_agents.nil?

    available_agents = filter_agents_by_rate_limit(eligible_agents)
    agent = available_agents.empty? ? nil : round_robin_selector.select_agent(available_agents)

    log_assignment_decision(conversation, eligible_agents, available_agents, agent)

    agent
  end

  def log_assignment_decision(conversation, eligible_agents, available_agents, agent)
    AgentAssignmentLog.record!(
      inbox: inbox,
      conversation: conversation,
      eligible_agent_ids: eligible_agents.map(&:user_id),
      available_agent_ids: available_agents.map(&:user_id),
      assigned_agent_id: agent&.id
    )
  end

  def filter_agents_by_team(agents, conversation)
    return agents if conversation&.team_id.blank?

    team = conversation.team
    return nil if team.blank? || team.allow_auto_assign.blank?

    team_member_ids = team.members.ids
    agents.where(user_id: team_member_ids)
  end

  def filter_agents_by_rate_limit(agents)
    agents.select do |agent_member|
      rate_limiter = build_rate_limiter(agent_member.user)
      rate_limiter.within_limit?
    end
  end

  def assign_conversation(conversation, agent)
    Current.executed_by = inbox.assignment_policy || inbox
    conversation.update!(assignee: agent)
    Current.executed_by = nil

    rate_limiter = build_rate_limiter(agent)
    rate_limiter.track_assignment(conversation)

    dispatch_assignment_event(conversation, agent)
    true
  ensure
    Current.executed_by = nil
  end

  def dispatch_assignment_event(conversation, agent)
    Rails.configuration.dispatcher.dispatch(
      Events::Types::ASSIGNEE_CHANGED,
      Time.zone.now,
      conversation: conversation,
      user: agent
    )
  end

  def build_rate_limiter(agent)
    AutoAssignment::RateLimiter.new(inbox: inbox, agent: agent)
  end

  def round_robin_selector
    @round_robin_selector ||= AutoAssignment::RoundRobinSelector.new(inbox: inbox)
  end
end

AutoAssignment::AssignmentService.prepend_mod_with('AutoAssignment::AssignmentService')
