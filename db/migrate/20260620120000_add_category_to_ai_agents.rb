class AddCategoryToAiAgents < ActiveRecord::Migration[7.1]
  def change
    add_column :ai_agents, :category, :string
  end
end
