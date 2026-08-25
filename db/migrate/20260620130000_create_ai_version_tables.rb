class CreateAiVersionTables < ActiveRecord::Migration[7.1]
  def change
    create_table :ai_agent_versions do |t|
      t.bigint :account_id, null: false
      t.bigint :ai_agent_id, null: false
      t.integer :version_number, null: false, default: 1
      t.jsonb :snapshot, null: false, default: {}
      t.string :note
      t.timestamps
    end
    add_index :ai_agent_versions, %i[ai_agent_id version_number]

    create_table :ai_playbook_versions do |t|
      t.bigint :account_id, null: false
      t.bigint :ai_department_id, null: false
      t.bigint :ai_playbook_id
      t.integer :version_number, null: false, default: 1
      t.jsonb :snapshot, null: false, default: {}
      t.string :note
      t.timestamps
    end
    add_index :ai_playbook_versions, %i[ai_department_id version_number]
  end
end
