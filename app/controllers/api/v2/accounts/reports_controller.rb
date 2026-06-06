class Api::V2::Accounts::ReportsController < Api::V1::Accounts::BaseController
  include Api::V2::Accounts::ReportsHelper
  include Api::V2::Accounts::HeatmapHelper

  before_action :check_authorization

  def index
    builder = V2::Reports::Conversations::ReportBuilder.new(Current.account, report_params)
    data = builder.timeseries
    render json: data
  end

  def summary
    render json: build_summary(:summary)
  end

  def bot_summary
    render json: build_summary(:bot_summary)
  end

  def agents
    @report_data = generate_agents_report
    generate_csv('agents_report', 'api/v2/accounts/reports/agents')
  end

  def inboxes
    @report_data = generate_inboxes_report
    generate_csv('inboxes_report', 'api/v2/accounts/reports/inboxes')
  end

  def labels
    @report_data = generate_labels_report
    generate_csv('labels_report', 'api/v2/accounts/reports/labels')
  end

  def teams
    @report_data = generate_teams_report
    generate_csv('teams_report', 'api/v2/accounts/reports/teams')
  end

  def conversations_summary
    @report_data = generate_conversations_report
    generate_csv('conversations_summary_report', 'api/v2/accounts/reports/conversations_summary')
  end

  def conversation_traffic
    @report_data = generate_conversations_heatmap_report
    timezone_offset = (params[:timezone_offset] || 0).to_f
    @timezone = ActiveSupport::TimeZone[timezone_offset]

    generate_csv('conversation_traffic_reports', 'api/v2/accounts/reports/conversation_traffic')
  end

  def conversations
    return head :unprocessable_entity if params[:type].blank?

    render json: conversation_metrics
  end

  def bot_metrics
    bot_metrics = V2::Reports::BotMetricsBuilder.new(Current.account, params).metrics
    render json: bot_metrics
  end

  def inbox_label_matrix
    builder = V2::Reports::InboxLabelMatrixBuilder.new(
      account: Current.account,
      params: inbox_label_matrix_params
    )
    render json: builder.build
  end

  def first_response_time_distribution
    builder = V2::Reports::FirstResponseTimeDistributionBuilder.new(
      account: Current.account,
      params: first_response_time_distribution_params
    )
    render json: builder.build
  end

  OUTGOING_MESSAGES_ALLOWED_GROUP_BY = %w[agent team inbox label].freeze

  def outgoing_messages_count
    return head :unprocessable_entity unless OUTGOING_MESSAGES_ALLOWED_GROUP_BY.include?(params[:group_by])

    builder = V2::Reports::OutgoingMessagesCountBuilder.new(Current.account, outgoing_messages_count_params)
    render json: builder.build
  end

  def conversation_distribution
    builder = V2::Reports::ConversationDistributionBuilder.new(
      account: Current.account,
      params: distribution_params
    )
    render json: builder.build
  end

  private

  def generate_csv(filename, template)
    response.headers['Content-Type'] = 'text/csv'
    response.headers['Content-Disposition'] = "attachment; filename=#{filename}.csv"
    render layout: false, template: template, formats: [:csv]
  end

  def check_authorization
    authorize :report, :view?
  end

  def common_params
    {
      type: params[:type].to_sym,
      id: params[:id],
      group_by: params[:group_by],
      business_hours: ActiveModel::Type::Boolean.new.cast(params[:business_hours])
    }
  end

  def current_summary_params
    common_params.merge({
                          since: range[:current][:since],
                          until: range[:current][:until],
                          timezone_offset: params[:timezone_offset]
                        })
  end

  def previous_summary_params
    common_params.merge({
                          since: range[:previous][:since],
                          until: range[:previous][:until],
                          timezone_offset: params[:timezone_offset]
                        })
  end

  def report_params
    common_params.merge({
                          metric: params[:metric],
                          since: params[:since],
                          until: params[:until],
                          timezone_offset: params[:timezone_offset]
                        })
  end

  def conversation_params
    {
      type: params[:type].to_sym,
      user_id: params[:user_id],
      page: params[:page].presence || 1
    }
  end

  def range
    {
      current: {
        since: params[:since],
        until: params[:until]
      },
      previous: {
        since: (params[:since].to_i - (params[:until].to_i - params[:since].to_i)).to_s,
        until: params[:since]
      }
    }
  end

  def build_summary(method)
    builder = V2::Reports::Conversations::MetricBuilder
    current_summary = builder.new(Current.account, current_summary_params.merge(account_user: Current.account_user)).send(method)
    previous_summary = builder.new(Current.account, previous_summary_params.merge(account_user: Current.account_user)).send(method)
    current_summary.merge(previous: previous_summary)
  end

  def conversation_metrics
    V2::ReportBuilder.new(Current.account, conversation_params).conversation_metrics
  end

  def inbox_label_matrix_params
    {
      since: params[:since],
      until: params[:until],
      inbox_ids: params[:inbox_ids],
      label_ids: params[:label_ids]
    }
  end

  def first_response_time_distribution_params
    {
      since: params[:since],
      until: params[:until]
    }
  end

  def outgoing_messages_count_params
    {
      group_by: params[:group_by],
      since: params[:since],
      until: params[:until]
    }
  end

  def distribution_params
    {
      since:        params[:since],
      until:        params[:until],
      inbox_id:     params[:inbox_id],
      team_id:      params[:team_id],
      account_user: Current.account_user
    }
  end

  # Native result enum values (see Conversation: none/won/lost). Reports read the first-class
  # `result` column directly. `ai_closed` is intentionally NOT a business result (it maps to
  # result=none), so it is still read from additional_attributes.outcome.
  RESULT_WON = Conversation.results['won']
  RESULT_LOST = Conversation.results['lost']
  RESULT_NONE = Conversation.results['none']

  OUTCOME_SELECT = <<~SQL.freeze
    COUNT(*) AS total,
    SUM(CASE WHEN conversations.result = #{RESULT_WON}  THEN 1 ELSE 0 END) AS won,
    SUM(CASE WHEN conversations.result = #{RESULT_LOST} THEN 1 ELSE 0 END) AS lost,
    SUM(CASE WHEN conversations.additional_attributes ->> 'outcome' = 'ai_closed' THEN 1 ELSE 0 END) AS ai_closed,
    SUM(CASE WHEN conversations.status = 'pending'                                 THEN 1 ELSE 0 END) AS pending,
    SUM(CASE WHEN reopened_convs.conversation_id IS NOT NULL                       THEN 1 ELSE 0 END) AS reopened,
    SUM(CASE WHEN conversations.status = 'resolved'
              AND conversations.result = #{RESULT_NONE}
              AND COALESCE(conversations.additional_attributes ->> 'outcome', '') <> 'ai_closed' THEN 1 ELSE 0 END) AS no_outcome
  SQL

  def leads_summary
    scope = build_leads_scope
    render json: {
      summary:   build_summary_row(scope),
      by_agent:  leads_by_agent(scope),
      by_inbox:  leads_by_inbox(scope),
      by_origin: leads_by_origin(scope),
      by_team:   leads_by_team(scope),
      by_number: leads_by_number(scope)
    }
  end

  def marketing_summary
    scope = build_leads_scope
              .where("conversations.additional_attributes -> 'attribution' ->> 'ctwa_clid' IS NOT NULL")
    render json: {
      summary:      build_summary_row(scope),
      by_agent:     leads_by_agent(scope),
      by_campaign:  marketing_by_campaign(scope),
      by_inbox:     leads_by_inbox(scope),
      by_media:     marketing_by_media(scope),
      by_ad:        marketing_by_ad(scope)
    }
  end

  def schedule_report
    render json: {
      by_hour:          conversations_by_hour,
      response_by_hour: first_response_by_hour,
      agent_by_hour:    agent_activity_by_hour
    }
  end

  private

  def build_leads_scope
    @value_key = Current.account.settings&.dig('meta_conversion_settings', 'value_field').presence

    scope = Reports::PermissionScopeService.new(Current.account_user).scope_conversations(
      Current.account.conversations.joins(reopen_join_sql)
    )
    scope = scope.where('conversations.created_at >= ?', Time.zone.at(params[:since].to_i))   if params[:since].present?
    scope = scope.where('conversations.created_at <= ?', Time.zone.at(params[:until].to_i))   if params[:until].present?
    scope = scope.where(inbox_id: params[:inbox_id])                                           if params[:inbox_id].present?
    scope = scope.where(team_id: params[:team_id])                                             if params[:team_id].present?
    scope = scope.where(assignee_id: params[:assignee_id])                                     if params[:assignee_id].present?
    scope
  end

  def reopen_join_sql
    <<~SQL
      LEFT JOIN (
        SELECT DISTINCT conversation_id
        FROM reporting_events
        WHERE account_id = #{Current.account.id}
          AND name = 'conversation_opened'
          AND value > 0
      ) AS reopened_convs ON reopened_convs.conversation_id = conversations.id
    SQL
  end

  def outcome_select_sql
    base = OUTCOME_SELECT.chomp
    if @value_key.present?
      safe_key = @value_key.gsub(/[^a-zA-Z0-9_]/, '')
      "#{base},\n" \
        "    COALESCE(SUM(CASE WHEN conversations.result = #{RESULT_WON} " \
        "THEN NULLIF(conversations.custom_attributes->>'#{safe_key}', '')::numeric ELSE NULL END), 0) AS revenue,\n" \
        "    COALESCE(SUM(CASE WHEN conversations.result = #{RESULT_LOST} " \
        "THEN NULLIF(conversations.custom_attributes->>'#{safe_key}', '')::numeric ELSE NULL END), 0) AS revenue_lost"
    else
      "#{base},\n    0::numeric AS revenue,\n    0::numeric AS revenue_lost"
    end
  end

  def leads_by_agent(scope)
    scope.joins('LEFT JOIN users ON users.id = conversations.assignee_id')
         .group('users.id, users.name')
         .select("users.id, COALESCE(users.name, 'Sem atribuição') AS name, #{outcome_select_sql}")
         .map { |r| row_with_open(r, id: r.id, name: r.name) }
         .sort_by { |r| -r[:total] }
  end

  def leads_by_inbox(scope)
    scope.joins(:inbox)
         .group('inboxes.id, inboxes.name, inboxes.channel_type')
         .select("inboxes.id, inboxes.name, inboxes.channel_type, #{outcome_select_sql}")
         .map { |r| row_with_open(r, id: r.id, name: r.name, channel_type: r.channel_type) }
         .sort_by { |r| -r[:total] }
  end

  def leads_by_origin(scope)
    scope.joins(:inbox)
         .group('inboxes.channel_type')
         .select("inboxes.channel_type AS origin, #{outcome_select_sql}")
         .map { |r| row_with_open(r, origin: r.origin) }
         .sort_by { |r| -r[:total] }
  end

  def leads_by_team(scope)
    scope.joins('LEFT JOIN teams ON teams.id = conversations.team_id')
         .group('teams.id, teams.name')
         .select("teams.id, COALESCE(teams.name, 'Sem equipe') AS name, #{outcome_select_sql}")
         .map { |r| row_with_open(r, id: r.id, name: r.name) }
         .sort_by { |r| -r[:total] }
  end

  def leads_by_number(scope)
    scope.joins(:inbox)
         .where("inboxes.phone_number IS NOT NULL AND inboxes.phone_number <> ''")
         .group('inboxes.phone_number, inboxes.name')
         .select("inboxes.phone_number AS number, inboxes.name, #{outcome_select_sql}")
         .map { |r| row_with_open(r, number: r.number, name: r.name) }
         .sort_by { |r| -r[:total] }
  end

  def marketing_by_campaign(scope)
    scope.group("conversations.additional_attributes -> 'attribution' ->> 'utm_campaign'")
         .select("conversations.additional_attributes -> 'attribution' ->> 'utm_campaign' AS campaign, #{outcome_select_sql}")
         .map { |r| row_with_open(r, campaign: r.campaign.presence || '(sem campanha)') }
         .sort_by { |r| -r[:total] }
  end

  def marketing_by_media(scope)
    scope.group("conversations.additional_attributes -> 'attribution' ->> 'utm_medium'")
         .select("conversations.additional_attributes -> 'attribution' ->> 'utm_medium' AS media_type, #{outcome_select_sql}")
         .map { |r| row_with_open(r, media_type: r.media_type.presence || 'Não identificado') }
         .sort_by { |r| -r[:total] }
  end

  def marketing_by_ad(scope)
    scope.group("conversations.additional_attributes -> 'attribution' ->> 'utm_content', " \
                "conversations.additional_attributes -> 'attribution' ->> 'utm_campaign'")
         .select("conversations.additional_attributes -> 'attribution' ->> 'utm_content'  AS ad_id, " \
                 "conversations.additional_attributes -> 'attribution' ->> 'utm_campaign' AS campaign, #{outcome_select_sql}")
         .map { |r| row_with_open(r, ad_id: r.ad_id.presence || '—', campaign: r.campaign.presence || '—') }
         .sort_by { |r| -r[:total] }
  end

  def build_summary_row(scope)
    r = scope.select(outcome_select_sql).take
    row_with_open(r)
  end

  def row_with_open(record, extra = {})
    total        = record.total.to_i
    won          = record.won.to_i
    lost         = record.lost.to_i
    ai_closed    = record.ai_closed.to_i
    pending      = record.respond_to?(:pending) ? record.pending.to_i : 0
    open         = total - won - lost - ai_closed
    attended     = total - pending
    revenue      = record.respond_to?(:revenue)      ? record.revenue.to_f.round(2)      : 0.0
    revenue_lost = record.respond_to?(:revenue_lost) ? record.revenue_lost.to_f.round(2) : 0.0
    reopened     = record.try(:reopened).to_i
    no_outcome   = record.try(:no_outcome).to_i
    concluded    = won + lost
    rate         = concluded.positive? ? (won.to_f / concluded * 100).round(1) : 0.0
    reopen_rate  = total.positive? ? (reopened.to_f / total * 100).round(1) : 0.0
    extra.merge(
      total:, won:, lost:, open:, ai_closed:, pending:, attended:,
      no_outcome:, revenue:, revenue_lost:,
      conversion_rate: rate, reopened:, reopen_rate:
    )
  end

  # ── Schedule report helpers ─────────────────────────────────────────────────

  def schedule_scope
    tz_offset = (params[:timezone_offset] || 0).to_f
    tz = ActiveSupport::TimeZone[tz_offset] || Time.zone
    scope = Reports::PermissionScopeService.new(Current.account_user).scope_conversations(
      Current.account.conversations
    )
    scope = scope.where('conversations.created_at >= ?', Time.zone.at(params[:since].to_i)) if params[:since].present?
    scope = scope.where('conversations.created_at <= ?', Time.zone.at(params[:until].to_i)) if params[:until].present?
    scope = scope.where(inbox_id: params[:inbox_id])       if params[:inbox_id].present?
    scope = scope.where(team_id: params[:team_id])         if params[:team_id].present?
    scope = scope.where(assignee_id: params[:assignee_id]) if params[:assignee_id].present?
    [scope, tz]
  end

  def conversations_by_hour
    scope, tz = schedule_scope
    scope
      .group("EXTRACT(HOUR FROM conversations.created_at AT TIME ZONE '#{tz.tzinfo.name}')::int")
      .order(Arel.sql("1"))
      .count
      .map { |hour, count| { hour: hour, total: count } }
  end

  def first_response_by_hour
    scope, tz = schedule_scope
    scope
      .joins("JOIN reporting_events re ON re.conversation_id = conversations.id AND re.name = 'first_response'")
      .group("EXTRACT(HOUR FROM conversations.created_at AT TIME ZONE '#{tz.tzinfo.name}')::int")
      .order(Arel.sql("1"))
      .average('re.value')
      .map { |hour, avg| { hour: hour, avg_seconds: avg&.round(0).to_i } }
  end

  def agent_activity_by_hour
    scope, tz = schedule_scope
    scope
      .joins('LEFT JOIN users ON users.id = conversations.assignee_id')
      .where('conversations.assignee_id IS NOT NULL')
      .group("users.id, users.name, EXTRACT(HOUR FROM conversations.created_at AT TIME ZONE '#{tz.tzinfo.name}')::int")
      .order(Arel.sql("1, 2, 3"))
      .count
      .map do |(user_id, name, hour), count|
        { agent_id: user_id, agent: name, hour: hour, total: count }
      end
  end
end
