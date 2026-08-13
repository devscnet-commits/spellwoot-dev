# Backend foundation for the 7-tab Agente IA redesign (departments kept as a layer).
# Additive only. New: lead variables (Instruções tab); agent identity fields (Sobre tab);
# department behavior + follow-up config (Comportamento/Follow-up tabs).
class AddAiCoreRedesignFields < ActiveRecord::Migration[7.1]
  def change
    # Sobre (agent identity)
    add_column :ai_agents, :company_name, :string
    add_column :ai_agents, :site, :string
    add_column :ai_agents, :version, :string
    add_column :ai_agents, :identify_as, :string, default: 'ai' # ai | human

    # Comportamento + Follow-up (per department)
    add_column :ai_departments, :behavior, :jsonb, null: false, default: {}
    add_column :ai_departments, :follow_up, :jsonb, null: false, default: {}

    # Variáveis do lead (Instruções tab) — collected during the conversation
    create_table :ai_lead_variables do |t|
      t.bigint :account_id, null: false
      t.bigint :ai_department_id, null: false
      t.string :name, null: false
      t.text   :description
      t.string :var_type, null: false, default: 'texto' # texto | numero | booleano | lista
      t.jsonb  :values, null: false, default: []
      t.boolean :visible_in_first_chat, null: false, default: false
      t.integer :position, null: false, default: 0
      t.timestamps
    end
    add_index :ai_lead_variables, :ai_department_id
  end
end
