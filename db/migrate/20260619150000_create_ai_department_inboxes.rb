# Maps an inbox to one or more AI departments, so a message can be routed to the right
# department within the resolved agent. Additive; ai_* only.
class CreateAiDepartmentInboxes < ActiveRecord::Migration[7.1]
  def change
    create_table :ai_department_inboxes do |t|
      t.bigint :ai_department_id, null: false
      t.bigint :inbox_id, null: false
      t.timestamps
    end
    add_index :ai_department_inboxes, [:ai_department_id, :inbox_id], unique: true,
                                                                       name: 'idx_ai_department_inboxes_unique'
    add_index :ai_department_inboxes, :inbox_id
  end
end
