class AddActiveAndReceivesAssignmentsToAccountUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :account_users, :active, :boolean, default: true, null: false
    add_column :account_users, :receives_assignments, :boolean, default: true, null: false
    add_index :account_users, :active
  end
end
