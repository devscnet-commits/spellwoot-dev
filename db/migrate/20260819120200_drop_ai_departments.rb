# Fusão Departamento -> Agente, passo 3/3 (final, IRREVERSÍVEL nos dados): remove tudo que já foi
# copiado pro Agente/ai_agent_id nas 2 migrações anteriores. down recria só a ESTRUTURA vazia (sem
# dados), mesmo padrão de db/migrate/20260716120000_drop_legacy_ai_version_tables.rb.
class DropAiDepartments < ActiveRecord::Migration[7.1]
  def up
    add_index :ai_department_integrations, %i[ai_agent_id ai_integration_link_id],
              unique: true, name: 'idx_ai_agent_integrations_unique'
    change_column_null :ai_department_integrations, :ai_agent_id, false
    change_column_null :ai_lead_variables, :ai_agent_id, false
    change_column_null :ai_playbooks, :ai_agent_id, false

    remove_column :ai_department_integrations, :ai_department_id, :bigint
    remove_column :ai_knowledge_sources, :ai_department_id, :bigint
    remove_column :ai_lead_variables, :ai_department_id, :bigint
    remove_column :ai_playbooks, :ai_department_id, :bigint
    remove_column :ai_runs, :ai_department_id, :bigint
    remove_column :ai_tools, :ai_department_id, :bigint

    drop_table :ai_department_inboxes
    drop_table :ai_departments
  end

  def down
    add_column :ai_department_integrations, :ai_department_id, :bigint, null: false
    add_column :ai_knowledge_sources, :ai_department_id, :bigint
    add_column :ai_lead_variables, :ai_department_id, :bigint, null: false
    add_column :ai_playbooks, :ai_department_id, :bigint, null: false
    add_column :ai_runs, :ai_department_id, :bigint
    add_column :ai_tools, :ai_department_id, :bigint

    add_index :ai_department_integrations, :ai_department_id
    add_index :ai_knowledge_sources, :ai_department_id
    add_index :ai_lead_variables, :ai_department_id
    add_index :ai_playbooks, :ai_department_id
    add_index :ai_runs, :ai_department_id
    add_index :ai_tools, :ai_department_id

    remove_index :ai_department_integrations, name: 'idx_ai_agent_integrations_unique'
    change_column_null :ai_department_integrations, :ai_agent_id, true
    change_column_null :ai_lead_variables, :ai_agent_id, true
    change_column_null :ai_playbooks, :ai_agent_id, true

    create_table :ai_departments do |t|
      t.bigint :account_id, null: false
      t.bigint :ai_agent_id, null: false
      t.string :name, null: false
      t.text :objetivo
      t.string :status, null: false, default: 'active'
      t.jsonb :sla, null: false, default: {}
      t.jsonb :transfer_rules, null: false, default: {}
      t.jsonb :close_rules, null: false, default: {}
      t.jsonb :copilot_config, null: false, default: {}
      t.jsonb :auto_attendance_config, null: false, default: {}
      t.jsonb :behavior, null: false, default: {}
      t.jsonb :follow_up, null: false, default: {}
      t.text :instructions
      t.boolean :is_default, null: false, default: false
      t.integer :position, null: false, default: 0
      t.timestamps
    end
    add_index :ai_departments, :ai_agent_id

    create_table :ai_department_inboxes do |t|
      t.bigint :ai_department_id, null: false
      t.bigint :inbox_id, null: false
      t.timestamps
    end
    add_index :ai_department_inboxes, %i[ai_department_id inbox_id],
              unique: true, name: 'idx_ai_department_inboxes_unique'
    add_index :ai_department_inboxes, :inbox_id
  end
end
