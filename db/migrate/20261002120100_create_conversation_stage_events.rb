class CreateConversationStageEvents < ActiveRecord::Migration[7.1]
  # One row per pipeline stage change: feeds the funnel/time-in-stage reports and lets a cleared
  # result send the card back to the stage it came from.
  def change
    create_table :conversation_stage_events do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.references :conversation, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :operational_flow, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :from_stage, foreign_key: { to_table: :resolution_states, on_delete: :nullify }, index: false
      t.references :to_stage, foreign_key: { to_table: :resolution_states, on_delete: :nullify }
      t.references :user, index: false
      t.string :source, null: false, default: 'manual'
      t.datetime :created_at, null: false
    end

    add_index :conversation_stage_events, %i[conversation_id created_at], name: 'idx_stage_events_conversation_created'
    add_index :conversation_stage_events, %i[operational_flow_id created_at], name: 'idx_stage_events_flow_created'
  end
end
