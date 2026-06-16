class AddCategoryAndResolutionStates < ActiveRecord::Migration[7.0]
  def change
    add_column :operational_flows, :category, :string, null: false, default: 'sales'

    create_table :resolution_states do |t|
      t.references :operational_flow, null: false, foreign_key: true
      t.string :canonical_key, null: false
      t.string :display_label, null: false
      t.string :polarity, null: false, default: 'neutral'
      t.boolean :requires_reason, null: false, default: false
      t.integer :sort_order, null: false, default: 0

      t.timestamps
    end

    add_index :resolution_states, %i[operational_flow_id canonical_key], unique: true, name: 'idx_resolution_states_flow_canonical'

    add_reference :operational_flow_reasons, :resolution_state, foreign_key: true, null: true
  end
end
