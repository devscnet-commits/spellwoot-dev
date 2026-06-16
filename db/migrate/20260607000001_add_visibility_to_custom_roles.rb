class AddVisibilityToCustomRoles < ActiveRecord::Migration[7.0]
  # visibility_scope is nullable on purpose: existing roles stay NULL and keep the legacy
  # (inbox ∪ elevated-team) visibility, so nothing changes on rollout. An explicit scope is an
  # opt-in override set per role. can_view_unassigned_queue only applies to own/team scopes.
  def change
    add_column :custom_roles, :visibility_scope, :string
    add_column :custom_roles, :can_view_unassigned_queue, :boolean, null: false, default: true
  end
end
