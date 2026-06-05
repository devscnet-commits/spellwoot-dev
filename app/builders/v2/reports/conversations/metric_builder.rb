class V2::Reports::Conversations::MetricBuilder < V2::Reports::Conversations::BaseReportBuilder
  def summary
    total = count('conversations_count')
    reopened = count('reopened_conversations_count')
    {
      conversations_count: total,
      incoming_messages_count: count('incoming_messages_count'),
      outgoing_messages_count: count('outgoing_messages_count'),
      avg_first_response_time: count('avg_first_response_time'),
      avg_resolution_time: count('avg_resolution_time'),
      resolutions_count: count('resolutions_count'),
      reply_time: count('reply_time'),
      reopened_conversations_count: reopened,
      reopen_rate: total.positive? ? (reopened.to_f / total * 100).round(1) : 0.0,
      avg_time_to_reopen: count('avg_time_to_reopen')
    }
  end

  def bot_summary
    {
      bot_resolutions_count: count('bot_resolutions_count'),
      bot_handoffs_count: count('bot_handoffs_count')
    }
  end

  private

  def count(metric)
    builder_class(metric).new(account, builder_params(metric)).aggregate_value
  end

  def builder_params(metric)
    params.merge({ metric: metric })
  end
end
