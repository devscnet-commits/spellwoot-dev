class AddEligibleForAssignmentToInboxMembers < ActiveRecord::Migration[7.0]
  def change
    add_column :inbox_members, :eligible_for_assignment, :boolean, default: true, null: false
  end
end
