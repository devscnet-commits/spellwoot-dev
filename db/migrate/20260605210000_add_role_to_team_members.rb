class AddRoleToTeamMembers < ActiveRecord::Migration[7.1]
  def change
    add_column :team_members, :role, :integer, default: 0, null: false
    add_index :team_members, :role
  end
end
