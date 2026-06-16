class CreateConversationResultEvents < ActiveRecord::Migration[7.0]
  def change
    create_table :conversation_result_events do |t|
      t.references :conversation, null: false, foreign_key: true
      t.bigint :account_id, null: false
      t.bigint :inbox_id
      t.bigint :team_id
      t.bigint :user_id
      t.integer :result, null: false, default: 0
      t.integer :previous_result
      t.string :result_reason
      t.string :event_type, null: false, default: 'set'
      t.string :ip_address

      t.timestamps
    end

    add_index :conversation_result_events, %i[account_id created_at], name: 'idx_cre_account_created'
    add_index :conversation_result_events, %i[conversation_id created_at], name: 'idx_cre_conversation_created'
  end
end
