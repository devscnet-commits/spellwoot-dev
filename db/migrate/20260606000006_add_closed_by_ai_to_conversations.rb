class AddClosedByAiToConversations < ActiveRecord::Migration[7.0]
  disable_ddl_transaction!

  def up
    add_column :conversations, :closed_by_ai, :boolean, default: false, null: false

    # Backfill the native flag one last time from the legacy additional_attributes.outcome.
    execute <<~SQL.squish
      UPDATE conversations SET closed_by_ai = true
      WHERE additional_attributes ->> 'outcome' = 'ai_closed'
    SQL
  end

  def down
    remove_column :conversations, :closed_by_ai
  end
end
