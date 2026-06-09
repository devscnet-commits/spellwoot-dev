class CreateOperationalFlows < ActiveRecord::Migration[7.0]
  def change
    create_table :operational_flows do |t|
      t.references :account, null: false, foreign_key: true
      t.string :name, null: false
      t.boolean :require_reason, null: false, default: false
      t.boolean :active, null: false, default: true

      t.timestamps
    end

    add_index :operational_flows, %i[account_id name], unique: true
  end
end
