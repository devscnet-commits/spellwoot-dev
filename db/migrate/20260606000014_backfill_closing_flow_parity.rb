class BackfillClosingFlowParity < ActiveRecord::Migration[7.0]
  # Self-contained AR classes so the backfill is decoupled from future app-model changes.
  class MigrationFlow < ApplicationRecord
    self.table_name = 'operational_flows'
  end

  class MigrationState < ApplicationRecord
    self.table_name = 'resolution_states'
  end

  class MigrationReason < ApplicationRecord
    self.table_name = 'operational_flow_reasons'
  end

  class MigrationRequirement < ApplicationRecord
    self.table_name = 'closing_requirements'
  end

  class MigrationRule < ApplicationRecord
    self.table_name = 'flow_assignment_rules'
  end

  class MigrationInbox < ApplicationRecord
    self.table_name = 'inboxes'
  end

  class MigrationAccount < ApplicationRecord
    self.table_name = 'accounts'
  end

  SEED_STATES = [
    { canonical_key: 'won', display_label: 'Ganho', polarity: 'positive', sort_order: 0, result: 1 },
    { canonical_key: 'lost', display_label: 'Perdido', polarity: 'negative', sort_order: 1, result: 2 }
  ].freeze

  def up
    MigrationFlow.find_each do |flow|
      seed_states_for(flow)
      seed_requirements_for(flow)
    end
    seed_default_rules
  end

  def down
    MigrationRule.delete_all
    MigrationRequirement.delete_all
    MigrationReason.update_all(resolution_state_id: nil)
    MigrationState.delete_all
  end

  private

  def seed_states_for(flow)
    SEED_STATES.each do |seed|
      state = MigrationState.find_or_create_by!(operational_flow_id: flow.id, canonical_key: seed[:canonical_key]) do |s|
        s.display_label = seed[:display_label]
        s.polarity = seed[:polarity]
        s.requires_reason = flow.require_reason
        s.sort_order = seed[:sort_order]
      end
      MigrationReason.where(operational_flow_id: flow.id, result: seed[:result], resolution_state_id: nil)
                     .update_all(resolution_state_id: state.id)
    end
  end

  def seed_requirements_for(flow)
    configs = required_attributes_for(flow.account_id)
    configs.each_with_index do |config, index|
      key = config['key']
      next if key.blank?

      MigrationRequirement.find_or_create_by!(operational_flow_id: flow.id, attribute_key: key) do |r|
        r.condition = condition_for(config)
        r.sort_order = index
      end
    end
  end

  def seed_default_rules
    MigrationInbox.where.not(operational_flow_id: nil).find_each do |inbox|
      MigrationRule.find_or_create_by!(account_id: inbox.account_id, operational_flow_id: inbox.operational_flow_id,
                                       predicate: { 'inbox_id' => inbox.id }) do |rule|
        rule.priority = 0
        rule.is_default = true
      end
    end
  end

  def required_attributes_for(account_id)
    account = MigrationAccount.find_by(id: account_id)
    raw = account&.settings&.dig('conversation_required_attributes') || []
    raw.map { |item| item.is_a?(String) ? { 'key' => item, 'rule' => 'always' } : item }
  end

  def condition_for(config)
    return { 'always' => true } unless config['rule'] == 'conditional'

    field = config['condition_field']
    value = config['condition_value']
    if field == '__resultado_conversa__'
      canonical = { 'ganho' => 'won', 'perdido' => 'lost' }[value]
      return { 'when' => { 'canonical_key' => canonical } } if canonical
    end
    { 'when' => { 'field' => field, 'value' => value } }
  end
end
