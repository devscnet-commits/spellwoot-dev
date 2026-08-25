# Persistent per-CONTACT memory that survives across conversations (unlike ai_agent_memory, which
# is per-conversation). One row per contact: a rolling summary + structured key_facts the AI reuses
# so it stops re-asking what the customer already told us. Written by CustomerMemoryUpdater when a
# conversation is resolved. Additive: does not touch the contacts table.
class CreateAiCustomerMemories < ActiveRecord::Migration[7.1]
  def change
    create_table :ai_customer_memories do |t|
      t.bigint   :contact_id, null: false
      t.bigint   :account_id, null: false
      t.text     :summary
      t.jsonb    :key_facts, null: false, default: {}
      t.integer  :conversations_count, null: false, default: 0
      t.datetime :last_updated_at
      t.timestamps
    end
    # One memory per contact (the decided scope). Also gives the natural upsert key.
    add_index :ai_customer_memories, [:contact_id, :account_id], unique: true
    add_index :ai_customer_memories, :account_id
  end
end
