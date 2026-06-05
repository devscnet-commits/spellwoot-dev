class V2::Reports::InboxSummaryBuilder < V2::Reports::BaseSummaryBuilder
  pattr_initialize [:account!, :params!]

  def build
    load_data
    prepare_report
  end

  private

  attr_reader :conversations_count, :resolved_count,
              :avg_resolution_time, :avg_first_response_time, :avg_reply_time,
              :reopened_count, :avg_time_to_reopen

  def load_data
    @conversations_count = fetch_conversations_count
    load_reporting_events_data
  end

  def fetch_conversations_count
    account.conversations.where(created_at: range).group(group_by_key).count
  end

  def prepare_report
    account.inboxes.map do |inbox|
      build_inbox_stats(inbox)
    end
  end

  def build_inbox_stats(inbox)
    total = conversations_count[inbox.id] || 0
    reopened = reopened_count[inbox.id] || 0
    {
      id: inbox.id,
      conversations_count: total,
      resolved_conversations_count: resolved_count[inbox.id] || 0,
      avg_resolution_time: avg_resolution_time[inbox.id],
      avg_first_response_time: avg_first_response_time[inbox.id],
      avg_reply_time: avg_reply_time[inbox.id],
      reopened_conversations_count: reopened,
      reopen_rate: total.positive? ? (reopened.to_f / total * 100).round(1) : 0.0,
      avg_time_to_reopen: avg_time_to_reopen[inbox.id]
    }
  end

  def group_by_key
    :inbox_id
  end

  def average_value_key
    ActiveModel::Type::Boolean.new.cast(params[:business_hours]) ? :value_in_business_hours : :value
  end
end
