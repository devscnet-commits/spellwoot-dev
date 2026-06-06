class CreateOperationalFlowReasons < ActiveRecord::Migration[7.0]
  def change
    create_table :operational_flow_reasons do |t|
      t.references :operational_flow, null: false, foreign_key: true
      t.integer :result, null: false
      t.string :label, null: false
      t.integer :position, null: false, default: 0
      t.boolean :active, null: false, default: true

      t.timestamps
    end

    add_index :operational_flow_reasons, %i[operational_flow_id result position], name: 'idx_ofr_flow_result_position'
  end
end
