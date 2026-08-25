# Shadow = an independent quality observer. It watches the inboxes linked to it and audits
# both human and AI handling, feeding the Validação screen. Created like an agent, but with
# evaluation instructions instead of a reply prompt.
class CreateAiShadows < ActiveRecord::Migration[7.1]
  def change
    create_table :ai_shadows do |t|
      t.bigint :account_id, null: false
      t.string :name, null: false
      t.text   :instructions
      t.jsonb  :scope, null: false, default: {}         # { observe_ai:, observe_human: }
      t.jsonb  :data_signals, null: false, default: {}  # which signals to surface in Validação
      t.string :status, null: false, default: 'active'
      t.timestamps
    end
    add_index :ai_shadows, :account_id

    create_table :ai_shadow_inboxes do |t|
      t.bigint :ai_shadow_id, null: false
      t.bigint :inbox_id, null: false
      t.timestamps
    end
    add_index :ai_shadow_inboxes, [:ai_shadow_id, :inbox_id], unique: true
    add_index :ai_shadow_inboxes, :inbox_id
  end
end
