class V2::Reports::TeamSummaryBuilder < V2::Reports::BaseSummaryBuilder
  pattr_initialize [:account!, :params!]

  private

  attr_reader :conversations_count, :resolved_count,
              :avg_resolution_time, :avg_first_response_time, :avg_reply_time,
              :reopened_count, :avg_time_to_reopen

  def fetch_conversations_count
    base = account.conversations.where(created_at: range)
    base = permission_scope.scope_conversations(base) if permission_scope
    base.group(:team_id).count
  end

  def reporting_events
    @reporting_events ||= begin
      base = account.reporting_events.where(created_at: range).where.not(team_id: nil)
      permission_scope ? permission_scope.scope_reporting_events(base) : base
    end
  end

  def prepare_report
    base = account.teams
    base = permission_scope.scope_teams(base) if permission_scope
    base.map { |team| build_team_stats(team) }
  end

  def build_team_stats(team)
    total = conversations_count[team.id] || 0
    reopened = reopened_count[team.id] || 0
    {
      id: team.id,
      conversations_count: total,
      resolved_conversations_count: resolved_count[team.id] || 0,
      avg_resolution_time: avg_resolution_time[team.id],
      avg_first_response_time: avg_first_response_time[team.id],
      avg_reply_time: avg_reply_time[team.id],
      reopened_conversations_count: reopened,
      reopen_rate: total.positive? ? (reopened.to_f / total * 100).round(1) : 0.0,
      avg_time_to_reopen: avg_time_to_reopen[team.id]
    }
  end

  def group_by_key
    :team_id
  end
end
