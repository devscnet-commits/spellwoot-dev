# Foundation for the AI Core (Agentes IA) — a domain fully separate from human agents (users).
# Every table is prefixed ai_ to make the boundary unmistakable. Additive only: nothing here
# touches conversations/contacts/users or any existing Chatwoot table.
class CreateAiCoreTables < ActiveRecord::Migration[7.1]
  def change
    # pgvector extension is already enabled in this database (used by Captain); reused technically.

    create_table :ai_operation_profiles do |t|
      t.bigint :account_id, null: false
      t.string :name, null: false # economico | balanceado | premium
      t.string :supervisor_provider, null: false # anthropic | openai | google | openrouter
      t.string :supervisor_model, null: false
      t.jsonb :worker_overrides, null: false, default: {}
      t.jsonb :budget, null: false, default: {}
      t.timestamps
    end
    add_index :ai_operation_profiles, :account_id

    create_table :ai_agents do |t|
      t.bigint :account_id, null: false
      t.bigint :ai_operation_profile_id
      t.string :name, null: false
      t.string :stage, null: false, default: 'sandbox' # production | staging | sandbox | experimental (lifecycle metadata only)
      t.string :status, null: false, default: 'active'
      # Identity (product-facing, configured by the company)
      t.string :assistant_name
      t.string :assistant_avatar
      t.text   :assistant_description
      t.text   :assistant_personality
      t.string :assistant_language, default: 'pt-BR'
      t.string :assistant_voice
      t.text   :base_prompt
      t.text   :guardrails
      t.jsonb  :identity, null: false, default: {}
      t.timestamps
    end
    add_index :ai_agents, :account_id

    # Which AI serves which inbox and how. Routing lives HERE (stage is not routing).
    create_table :ai_agent_inboxes do |t|
      t.bigint :ai_agent_id, null: false
      t.bigint :inbox_id, null: false
      t.string :mode, null: false, default: 'shadow' # live (responds) | shadow (observes + records only)
      t.boolean :active, null: false, default: true
      t.integer :priority, null: false, default: 1
      t.timestamps
    end
    add_index :ai_agent_inboxes, [:inbox_id, :mode]
    add_index :ai_agent_inboxes, [:ai_agent_id, :inbox_id], unique: true

    # Departments = configurable mini operational process under a single AI.
    create_table :ai_departments do |t|
      t.bigint :account_id, null: false
      t.bigint :ai_agent_id, null: false
      t.string :name, null: false
      t.text   :objetivo
      t.string :status, null: false, default: 'active'
      t.jsonb  :sla, null: false, default: {}
      t.jsonb  :transfer_rules, null: false, default: {}
      t.jsonb  :close_rules, null: false, default: {}
      t.jsonb  :copilot_config, null: false, default: {}
      t.jsonb  :auto_attendance_config, null: false, default: {}
      t.timestamps
    end
    add_index :ai_departments, :ai_agent_id

    # Structured playbook (the user fills structure; the system compiles it into the prompt).
    create_table :ai_playbooks do |t|
      t.bigint :ai_department_id, null: false
      t.text   :objetivo
      t.jsonb  :steps, null: false, default: []
      t.jsonb  :transfer_when, null: false, default: []
      t.jsonb  :close_when, null: false, default: []
      t.jsonb  :default_messages, null: false, default: {}
      t.integer :version, null: false, default: 1
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :ai_playbooks, :ai_department_id

    # User-facing Tool: wraps an internal capability (by key) OR an external integration.
    create_table :ai_tools do |t|
      t.bigint :account_id, null: false
      t.bigint :ai_department_id
      t.string :name, null: false
      t.text   :description
      t.string :implementation_type, null: false, default: 'capability' # capability | integration
      t.string :capability_key # e.g. contact.read, contact.update_attributes
      t.bigint :integration_link_id
      t.jsonb  :input_schema, null: false, default: {}
      t.jsonb  :output_schema, null: false, default: {}
      t.string :governance, null: false, default: 'allowed' # allowed | require_confirmation | require_approval
      t.string :status, null: false, default: 'active'
      t.timestamps
    end
    add_index :ai_tools, :ai_department_id

    create_table :ai_knowledge_sources do |t|
      t.bigint :account_id, null: false
      t.bigint :ai_department_id
      t.string :kind, null: false, default: 'faq' # faq | produto | promocao | procedimento | documento | website
      t.string :title
      t.text   :raw
      t.string :status, null: false, default: 'active'
      t.timestamps
    end
    add_index :ai_knowledge_sources, :ai_department_id

    create_table :ai_knowledge_chunks do |t|
      t.bigint :ai_knowledge_source_id, null: false
      t.text   :content, null: false
      t.vector :embedding, limit: 1536
      t.timestamps
    end
    add_index :ai_knowledge_chunks, :ai_knowledge_source_id
    add_index :ai_knowledge_chunks, :embedding, using: :ivfflat, opclass: :vector_cosine_ops,
                                                 name: 'idx_ai_knowledge_chunks_embedding'

    # Audit of every model generation.
    create_table :ai_runs do |t|
      t.bigint :account_id, null: false
      t.bigint :conversation_id
      t.bigint :ai_agent_id
      t.string :run_type, null: false, default: 'decision'
      t.string :mode, null: false, default: 'shadow'
      t.string :provider
      t.string :model
      t.integer :tokens_in, null: false, default: 0
      t.integer :tokens_out, null: false, default: 0
      t.decimal :cost, precision: 12, scale: 6, null: false, default: 0
      t.integer :latency_ms
      t.jsonb  :decision, null: false, default: {}
      t.string :status, null: false, default: 'recorded'
      t.timestamps
    end
    add_index :ai_runs, :conversation_id
    add_index :ai_runs, :account_id

    # Event-driven trail of the pipeline.
    create_table :ai_events do |t|
      t.bigint :account_id, null: false
      t.bigint :conversation_id
      t.bigint :ai_run_id
      t.bigint :parent_event_id
      t.string :event_type, null: false
      t.jsonb  :payload, null: false, default: {}
      t.string :status, null: false, default: 'ok'
      t.timestamps
    end
    add_index :ai_events, :conversation_id
    add_index :ai_events, :ai_run_id

    # Per-conversation memory.
    create_table :ai_agent_memory do |t|
      t.bigint :conversation_id, null: false
      t.bigint :ai_agent_id, null: false
      t.jsonb  :state, null: false, default: {}
      t.text   :summary
      t.timestamps
    end
    add_index :ai_agent_memory, [:conversation_id, :ai_agent_id], unique: true
  end
end
