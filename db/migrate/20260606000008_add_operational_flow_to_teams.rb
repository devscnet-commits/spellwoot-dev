class AddOperationalFlowToTeams < ActiveRecord::Migration[7.0]
  def change
    add_column :teams, :operational_flow_id, :bigint
    add_index :teams, :operational_flow_id
  end
end
