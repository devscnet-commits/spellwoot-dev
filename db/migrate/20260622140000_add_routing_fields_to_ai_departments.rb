# F1.3 — department routing fallback. `is_default` marks the department that receives a
# conversation when the classifier is unsure; `position` defines the resolution order.
# Additive only; both nullable-safe with defaults.
class AddRoutingFieldsToAiDepartments < ActiveRecord::Migration[7.1]
  def change
    add_column :ai_departments, :is_default, :boolean, null: false, default: false
    add_column :ai_departments, :position, :integer, null: false, default: 0
  end
end
