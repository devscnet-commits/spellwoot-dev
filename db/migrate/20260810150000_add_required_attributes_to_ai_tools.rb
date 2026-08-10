class AddRequiredAttributesToAiTools < ActiveRecord::Migration[7.1]
  def change
    add_column :ai_tools, :required_attributes, :jsonb, null: false, default: []
  end
end
