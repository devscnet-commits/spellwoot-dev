class CreateFlowAssignmentRules < ActiveRecord::Migration[7.0]
  def change
    create_table :flow_assignment_rules do |t|
      t.references :account, null: false, foreign_key: true
      t.references :operational_flow, null: false, foreign_key: true
      t.jsonb :predicate, null: false, default: {}
      t.integer :priority, null: false, default: 0
      t.boolean :is_default, null: false, default: false

      t.timestamps
    end

    add_index :flow_assignment_rules, %i[account_id priority]
  end
end
