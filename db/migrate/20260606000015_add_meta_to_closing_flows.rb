class AddMetaToClosingFlows < ActiveRecord::Migration[7.0]
  def change
    # Master Meta switch for the whole flow (gate above the per-state triggers).
    add_column :operational_flows, :meta_enabled, :boolean, null: false, default: false
    # Per-state Meta trigger: null = never fire; otherwise the standard Meta event name.
    # meta_value_attr holds the custom attribute key (string convention) to read the sale value from.
    add_column :resolution_states, :meta_event_type, :string
    add_column :resolution_states, :meta_value_attr, :string
  end
end
