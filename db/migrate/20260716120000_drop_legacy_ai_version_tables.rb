class DropLegacyAiVersionTables < ActiveRecord::Migration[7.1]
  # Remove as tabelas de versionamento dedicadas (ai_agent_versions, ai_playbook_versions) após a
  # migração para o Ai::Version polimórfico (ai_versions). O histórico antigo é DESCARTADO por decisão
  # de produto — não há backfill. Irreversível: `down` recria apenas a ESTRUTURA vazia (sem dados) para
  # não travar um rollback do schema.
  def up
    drop_table :ai_agent_versions
    drop_table :ai_playbook_versions
  end

  def down
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
