class V2::Reports::AgentSummaryBuilder < V2::Reports::BaseSummaryBuilder
  pattr_initialize [:account!, :params!]

  def build
    load_data
    prepare_report
  end

  private

  attr_reader :conversations_count, :resolved_count,
              :avg_resolution_time, :avg_first_response_time, :avg_reply_time,
              :reopened_count, :avg_time_to_reopen

  def fetch_conversations_count
    account.conversations.where(created_at: range).group('assignee_id').count
  end

  def prepare_report
    account.account_users.where(active: true).map do |account_user|
      build_agent_stats(account_user)
    end
  end

  def build_agent_stats(account_user)
    user_id = account_user.user_id
    total = conversations_count[user_id] || 0
    reopened = reopened_count[user_id] || 0
    {
      id: user_id,
      conversations_count: total,
      resolved_conversations_count: resolved_count[user_id] || 0,
      avg_resolution_time: avg_resolution_time[user_id],
      avg_first_response_time: avg_first_response_time[user_id],
      avg_reply_time: avg_reply_time[user_id],
      reopened_conversations_count: reopened,
      reopen_rate: total.positive? ? (reopened.to_f / total * 100).round(1) : 0.0,
      avg_time_to_reopen: avg_time_to_reopen[user_id]
    }
  end

  def group_by_key
    :user_id
  end
end
