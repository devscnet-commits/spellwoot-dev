class AddResultCategoryToConversations < ActiveRecord::Migration[7.0]
  def change
    add_column :conversations, :result_category, :string
    add_column :conversations, :result_canonical_key, :string
    add_column :conversation_result_events, :result_category, :string
    add_column :conversation_result_events, :result_canonical_key, :string
  end
end
