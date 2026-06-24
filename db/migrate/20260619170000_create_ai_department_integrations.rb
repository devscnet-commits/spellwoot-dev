# Which external integrations a department is allowed to use (Integrações tab). Join table.
class CreateAiDepartmentIntegrations < ActiveRecord::Migration[7.1]
  def change
    create_table :ai_department_integrations do |t|
      t.bigint :ai_department_id, null: false
      t.bigint :ai_integration_link_id, null: false
      t.timestamps
    end
    add_index :ai_department_integrations, %i[ai_department_id ai_integration_link_id],
              unique: true, name: 'idx_ai_dept_integrations_unique'
  end
end
