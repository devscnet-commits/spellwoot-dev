class ConvertFlowRulesToInboxFlows < ActiveRecord::Migration[7.1]
  # Closing flows are now a direct attribute of the caixa (inboxes.operational_flow_id).
  # Convert the team-based assignment rules into direct links, then retire the table.
  class MigrationRule < ActiveRecord::Base
    self.table_name = 'flow_assignment_rules'
  end

  class MigrationTeamInbox < ActiveRecord::Base
    self.table_name = 'team_inboxes'
  end

  class MigrationInbox < ActiveRecord::Base
    self.table_name = 'inboxes'
  end

  def up
    return unless table_exists?(:flow_assignment_rules)

    # Same evaluation order the resolver used (most specific first), first match wins —
    # only inboxes without a direct flow get one, so existing direct links are preserved.
    MigrationRule.order(:priority, :id).each do |rule|
      predicate = rule.predicate.presence || {}
      team_ids = Array(predicate['team_id'])
      excluded = Array(predicate['excluded_inbox_ids']).map(&:to_i)

      scope = MigrationInbox.where(account_id: rule.account_id, operational_flow_id: nil)
      scope = scope.where(id: MigrationTeamInbox.where(team_id: team_ids).select(:inbox_id)) if team_ids.any?
      scope = scope.where.not(id: excluded) if excluded.any?
      scope.update_all(operational_flow_id: rule.operational_flow_id)
    end

    drop_table :flow_assignment_rules
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
