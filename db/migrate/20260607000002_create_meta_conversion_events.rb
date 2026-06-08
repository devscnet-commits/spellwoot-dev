class CreateMetaConversionEvents < ActiveRecord::Migration[7.0]
  # Audit trail for every Meta Conversions API send (spec part A, §4-bis.4): the payload sent,
  # the deterministic event_id, the outcome status and Meta's response. Source of truth for
  # reconciling conversions later. Access token is never stored.
  def change
    create_table :meta_conversion_events do |t|
      t.references :account, null: false, foreign_key: true
      t.references :conversation, null: false, foreign_key: true
      t.string :event_name, null: false
      t.string :event_id
      t.string :status, null: false
      t.jsonb :payload
      t.text :response

      t.timestamps
    end

    add_index :meta_conversion_events, %i[account_id created_at]
  end
end
