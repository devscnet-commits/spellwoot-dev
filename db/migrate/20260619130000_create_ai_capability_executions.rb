# Audit + governance ledger for tool/capability executions. Additive; ai_* domain only.
# Nothing here runs in shadow mode — execution only happens for live bindings and passes the
# tool's governance gate. Mutating capabilities store rollback_data so an execution can be undone.
class CreateAiCapabilityExecutions < ActiveRecord::Migration[7.1]
  def change
    create_table :ai_capability_executions do |t|
      t.bigint :account_id, null: false
      t.bigint :conversation_id
      t.bigint :ai_tool_id
      t.bigint :ai_run_id
      t.string :capability_key, null: false
      t.jsonb  :input, null: false, default: {}
      t.jsonb  :output, null: false, default: {}
      # pending | executed | skipped | failed | reverted
      t.string :status, null: false, default: 'pending'
      t.string :governance, null: false, default: 'allowed'
      # not_required | pending | approved | rejected
      t.string :approval_status, null: false, default: 'not_required'
      t.string :requested_by, null: false, default: 'ai'
      t.bigint :approved_by_user_id
      t.jsonb  :rollback_data, null: false, default: {}
      t.text   :error
      t.timestamps
    end
    add_index :ai_capability_executions, :conversation_id
    add_index :ai_capability_executions, :account_id
    add_index :ai_capability_executions, :status
  end
end
