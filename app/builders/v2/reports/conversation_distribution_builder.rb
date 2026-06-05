class V2::Reports::ConversationDistributionBuilder
  pattr_initialize [:account!, :params!]

  def build
    scope = base_scope
    {
      by_inbox:    distribution_by_inbox(scope),
      by_team:     distribution_by_team(scope),
      by_campaign: distribution_by_campaign(scope)
    }
  end

  private

  DISTRIBUTION_SELECT = <<~SQL.freeze
    COUNT(*)                                               AS received,
    COUNT(conversations.assignee_id)                      AS distributed,
    COUNT(*) - COUNT(conversations.assignee_id)           AS unassigned
  SQL

  def base_scope
    scope = permission_scope.scope_conversations(account.conversations)
    scope = scope.where('conversations.created_at >= ?', Time.zone.at(params[:since].to_i)) if params[:since].present?
    scope = scope.where('conversations.created_at <= ?', Time.zone.at(params[:until].to_i)) if params[:until].present?
    scope = scope.where(inbox_id: params[:inbox_id])  if params[:inbox_id].present?
    scope = scope.where(team_id: params[:team_id])    if params[:team_id].present?
    scope
  end

  def distribution_by_inbox(scope)
    scope.joins(:inbox)
         .group('conversations.inbox_id, inboxes.name, inboxes.channel_type')
         .select("conversations.inbox_id AS id, inboxes.name, inboxes.channel_type, #{DISTRIBUTION_SELECT}")
         .map { |r| row(r, id: r.id, name: r.name, channel_type: r.channel_type) }
         .sort_by { |r| -r[:received] }
  end

  def distribution_by_team(scope)
    scope.joins('LEFT JOIN teams ON teams.id = conversations.team_id')
         .group('conversations.team_id, teams.name')
         .select("conversations.team_id AS id, COALESCE(teams.name, 'Sem time') AS name, #{DISTRIBUTION_SELECT}")
         .map { |r| row(r, id: r.id, name: r.name) }
         .sort_by { |r| -r[:received] }
  end

  def distribution_by_campaign(scope)
    scope.joins(:campaign)
         .group('conversations.campaign_id, campaigns.title')
         .select("conversations.campaign_id AS id, campaigns.title AS name, #{DISTRIBUTION_SELECT}")
         .map { |r| row(r, id: r.id, name: r.name) }
         .sort_by { |r| -r[:received] }
  end

  def row(record, extra = {})
    received    = record.received.to_i
    distributed = record.distributed.to_i
    unassigned  = record.unassigned.to_i
    extra.merge(
      received: received,
      distributed: distributed,
      unassigned: unassigned,
      distribution_rate: received.positive? ? (distributed.to_f / received * 100).round(1) : 0.0
    )
  end

  def permission_scope
    @permission_scope ||= Reports::PermissionScopeService.new(params[:account_user])
  end
end
