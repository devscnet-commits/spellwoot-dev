class AddOperationalFlowToInboxes < ActiveRecord::Migration[7.0]
  disable_ddl_transaction!

  def change
    add_column :inboxes, :operational_flow_id, :bigint
    add_index :inboxes, :operational_flow_id, algorithm: :concurrently
  end
end
