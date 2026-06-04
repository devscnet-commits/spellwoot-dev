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
    current_summary = builder.new(Current.account, current_summary_params).send(method)
    previous_summary = builder.new(Current.account, previous_summary_params).send(method)
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

  OUTCOME_SELECT = <<~SQL.freeze
    COUNT(*) AS total,
    SUM(CASE WHEN conversations.additional_attributes ->> 'outcome' = 'won'       THEN 1 ELSE 0 END) AS won,
    SUM(CASE WHEN conversations.additional_attributes ->> 'outcome' = 'lost'      THEN 1 ELSE 0 END) AS lost,
    SUM(CASE WHEN conversations.additional_attributes ->> 'outcome' = 'ai_closed' THEN 1 ELSE 0 END) AS ai_closed
  SQL

  def leads_summary
    scope = Current.account.conversations
    scope = scope.where('conversations.created_at >= ?', Time.zone.at(params[:since].to_i)) if params[:since].present?
    scope = scope.where('conversations.created_at <= ?', Time.zone.at(params[:until].to_i)) if params[:until].present?

    render json: {
      summary:  build_summary_row(scope),
      by_agent:  leads_by_agent(scope),
      by_inbox:  leads_by_inbox(scope),
      by_origin: leads_by_origin(scope),
      by_team:   leads_by_team(scope)
    }
  end

  def marketing_summary
    scope = Current.account.conversations
                   .where("conversations.additional_attributes -> 'attribution' ->> 'ctwa_clid' IS NOT NULL")
    scope = scope.where('conversations.created_at >= ?', Time.zone.at(params[:since].to_i)) if params[:since].present?
    scope = scope.where('conversations.created_at <= ?', Time.zone.at(params[:until].to_i)) if params[:until].present?

    render json: {
      summary:     build_summary_row(scope),
      by_agent:    leads_by_agent(scope),
      by_campaign: marketing_by_campaign(scope),
      by_inbox:    leads_by_inbox(scope)
    }
  end

  private

  def leads_by_agent(scope)
    scope.joins('LEFT JOIN users ON users.id = conversations.assignee_id')
         .group('users.id, users.name')
         .select("users.id, COALESCE(users.name, 'Sem atribuição') AS name, #{OUTCOME_SELECT}")
         .map { |r| row_with_open(r, id: r.id, name: r.name) }
         .sort_by { |r| -r[:total] }
  end

  def leads_by_inbox(scope)
    scope.joins(:inbox)
         .group('inboxes.id, inboxes.name, inboxes.channel_type')
         .select("inboxes.id, inboxes.name, inboxes.channel_type, #{OUTCOME_SELECT}")
         .map { |r| row_with_open(r, id: r.id, name: r.name, channel_type: r.channel_type) }
         .sort_by { |r| -r[:total] }
  end

  def leads_by_origin(scope)
    scope.joins(:inbox)
         .group('inboxes.channel_type')
         .select("inboxes.channel_type AS origin, #{OUTCOME_SELECT}")
         .map { |r| row_with_open(r, origin: r.origin) }
         .sort_by { |r| -r[:total] }
  end

  def leads_by_team(scope)
    scope.joins('LEFT JOIN teams ON teams.id = conversations.team_id')
         .group('teams.id, teams.name')
         .select("teams.id, COALESCE(teams.name, 'Sem equipe') AS name, #{OUTCOME_SELECT}")
         .map { |r| row_with_open(r, id: r.id, name: r.name) }
         .sort_by { |r| -r[:total] }
  end

  def marketing_by_campaign(scope)
    scope.group("conversations.additional_attributes -> 'attribution' ->> 'utm_campaign'")
         .select("conversations.additional_attributes -> 'attribution' ->> 'utm_campaign' AS campaign, #{OUTCOME_SELECT}")
         .map { |r| row_with_open(r, campaign: r.campaign.presence || '(sem campanha)') }
         .sort_by { |r| -r[:total] }
  end

  def build_summary_row(scope)
    r = scope.select(OUTCOME_SELECT).take
    row_with_open(r)
  end

  def row_with_open(record, extra = {})
    total     = record.total.to_i
    won       = record.won.to_i
    lost      = record.lost.to_i
    ai_closed = record.ai_closed.to_i
    open      = total - won - lost - ai_closed
    concluded = won + lost
    rate      = concluded.positive? ? (won.to_f / concluded * 100).round(1) : 0.0
    extra.merge(total:, won:, lost:, open:, ai_closed:, conversion_rate: rate)
  end
end
