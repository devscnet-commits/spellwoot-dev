class AddScopeToCustomRoles < ActiveRecord::Migration[7.0]
  def change
    add_column :custom_roles, :scope_type, :string, default: 'all', null: false
    add_column :custom_roles, :scope_ids, :integer, array: true, default: []
  end
end
