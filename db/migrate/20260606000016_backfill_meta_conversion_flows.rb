class BackfillMetaConversionFlows < ActiveRecord::Migration[7.0]
  # Map the legacy global Meta config onto the new per-flow/per-state model, preserving today's
  # behavior: accounts firing Purchase on close (strategy == 'on_close') keep firing it on the
  # sales flow's "won" state. Support flows stay silent (meta_enabled false / meta_event_type null
  # by default), so isolation is structural.
  class MigrationFlow < ApplicationRecord
    self.table_name = 'operational_flows'
  end

  class MigrationState < ApplicationRecord
    self.table_name = 'resolution_states'
  end

  class MigrationAccount < ApplicationRecord
    self.table_name = 'accounts'
  end

  def up
    MigrationFlow.where(category: 'sales').find_each do |flow|
      settings = meta_settings(flow.account_id)
      next unless settings['strategy'] == 'on_close'

      flow.update_columns(meta_enabled: true)
      MigrationState.where(operational_flow_id: flow.id, canonical_key: 'won')
                    .update_all(meta_event_type: 'Purchase', meta_value_attr: settings['value_field'])
      MigrationState.where(operational_flow_id: flow.id, canonical_key: 'lost')
                    .update_all(meta_event_type: nil)
    end
  end

  def down
    MigrationFlow.update_all(meta_enabled: false)
    MigrationState.update_all(meta_event_type: nil, meta_value_attr: nil)
  end

  private

  def meta_settings(account_id)
    account = MigrationAccount.find_by(id: account_id)
    account&.settings&.dig('meta_conversion_settings') || {}
  end
end
