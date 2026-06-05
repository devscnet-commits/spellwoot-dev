class V2::Reports::LabelSummaryBuilder < V2::Reports::BaseSummaryBuilder
  attr_reader :account, :params

  # rubocop:disable Lint/MissingSuper
  # the parent class has no initialize
  def initialize(account:, params:)
    @account = account
    @params = params

    timezone_offset = (params[:timezone_offset] || 0).to_f
    @timezone = ActiveSupport::TimeZone[timezone_offset]&.name
  end
  # rubocop:enable Lint/MissingSuper

  def build
    labels = account.labels.to_a
    return [] if labels.empty?

    report_data = collect_report_data
    labels.map { |label| build_label_report(label, report_data) }
  end

  private

  def collect_report_data
    conversation_filter = build_conversation_filter
    use_business_hours = use_business_hours?

    {
      conversation_counts: fetch_conversation_counts(conversation_filter),
      resolved_counts: fetch_resolved_counts,
      resolution_metrics: fetch_metrics(conversation_filter, 'conversation_resolved', use_business_hours),
      first_response_metrics: fetch_metrics(conversation_filter, 'first_response', use_business_hours),
      reply_metrics: fetch_metrics(conversation_filter, 'reply_time', use_business_hours),
      reopen_data: fetch_reopen_data(conversation_filter, use_business_hours)
    }
  end

  def build_label_report(label, report_data)
    total = report_data[:conversation_counts][label.title] || 0
    reopen = report_data[:reopen_data][label.title] || {}
    reopened = reopen[:count] || 0
    {
      id: label.id,
      name: label.title,
      conversations_count: total,
      avg_resolution_time: report_data[:resolution_metrics][label.title] || 0,
      avg_first_response_time: report_data[:first_response_metrics][label.title] || 0,
      avg_reply_time: report_data[:reply_metrics][label.title] || 0,
      resolved_conversations_count: report_data[:resolved_counts][label.title] || 0,
      reopened_conversations_count: reopened,
      reopen_rate: total.positive? ? (reopened.to_f / total * 100).round(1) : 0.0,
      avg_time_to_reopen: reopen[:avg_time]
    }
  end

  def use_business_hours?
    ActiveModel::Type::Boolean.new.cast(params[:business_hours])
  end

  def build_conversation_filter
    conversation_filter = { account_id: account.id }
    conversation_filter[:created_at] = range if range.present?
    conversation_filter
  end

  def fetch_conversation_counts(conversation_filter)
    fetch_counts(conversation_filter)
  end

  def fetch_resolved_counts
    reporting_event_filter = { name: 'conversation_resolved', account_id: account.id }
    reporting_event_filter[:created_at] = range if range.present?

    scope = ReportingEvent
              .joins(conversation: { taggings: :tag })
              .where(reporting_event_filter.merge(taggings: { taggable_type: 'Conversation', context: 'labels' }))
    scope = apply_conversation_permission_scope(scope)
    scope.group('tags.name').count
  end

  def permission_scope
    return @permission_scope if defined?(@permission_scope)

    @permission_scope = params[:account_user] ? Reports::PermissionScopeService.new(params[:account_user]) : nil
  end

  def apply_conversation_permission_scope(scope)
    return scope unless permission_scope
    return scope if permission_scope.admin?

    if permission_scope.agent_only?
      scope.where(conversations: { assignee_id: permission_scope.current_user_id })
    else
      scope.where(conversations: { team_id: permission_scope.accessible_team_ids })
    end
  end

  def fetch_counts(conversation_filter)
    ActsAsTaggableOn::Tagging
      .joins('INNER JOIN conversations ON taggings.taggable_id = conversations.id')
      .joins('INNER JOIN tags ON taggings.tag_id = tags.id')
      .where(
        taggable_type: 'Conversation',
        context: 'labels',
        conversations: conversation_filter
      )
      .select('tags.name, COUNT(taggings.*) AS count')
      .group('tags.name')
      .each_with_object({}) { |record, hash| hash[record.name] = record.count }
  end

  def fetch_metrics(conversation_filter, event_name, use_business_hours)
    scope = ReportingEvent
              .joins(conversation: { taggings: :tag })
              .where(conversations: conversation_filter, name: event_name,
                     taggings: { taggable_type: 'Conversation', context: 'labels' })
    scope = apply_conversation_permission_scope(scope)
    scope.group('tags.name')
         .order('tags.name')
         .select('tags.name',
                 use_business_hours ? 'AVG(reporting_events.value_in_business_hours) as avg_value'
                                    : 'AVG(reporting_events.value) as avg_value')
         .each_with_object({}) { |record, hash| hash[record.name] = record.avg_value.to_f }
  end

  def fetch_reopen_data(conversation_filter, use_business_hours)
    avg_col = use_business_hours ? 'reporting_events.value_in_business_hours' : 'reporting_events.value'
    scope = ReportingEvent
              .joins(conversation: { taggings: :tag })
              .where(conversations: conversation_filter, name: 'conversation_opened',
                     taggings: { taggable_type: 'Conversation', context: 'labels' })
              .where('reporting_events.value > 0')
    scope = apply_conversation_permission_scope(scope)
    scope.group('tags.name')
         .select("tags.name, COUNT(*) as reopen_count, AVG(#{avg_col}) as avg_time")
         .each_with_object({}) { |r, h| h[r.name] = { count: r.reopen_count, avg_time: r.avg_time } }
  end
end
