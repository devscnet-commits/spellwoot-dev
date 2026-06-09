class AddResultToConversations < ActiveRecord::Migration[7.0]
  disable_ddl_transaction!

  def up
    add_column :conversations, :result, :integer, default: 0, null: false
    add_column :conversations, :result_reason, :string
    add_column :conversations, :result_set_at, :datetime
    add_column :conversations, :result_set_by_id, :bigint

    add_index :conversations, %i[account_id result], algorithm: :concurrently

    # Backfill native result column from the legacy additional_attributes.outcome JSON.
    # ai_closed / blank outcomes stay as the default `none` (0).
    execute <<~SQL.squish
      UPDATE conversations
      SET result = CASE additional_attributes ->> 'outcome'
                     WHEN 'won'  THEN 1
                     WHEN 'lost' THEN 2
                     ELSE 0
                   END,
          result_set_at = NULLIF(additional_attributes ->> 'outcome_set_at', '')::timestamp
      WHERE additional_attributes ->> 'outcome' IN ('won', 'lost')
    SQL
  end

  def down
    remove_column :conversations, :result
    remove_column :conversations, :result_reason
    remove_column :conversations, :result_set_at
    remove_column :conversations, :result_set_by_id
  end
end
