class AddPriceToAiKnowledgeSources < ActiveRecord::Migration[7.1]
  def change
    add_column :ai_knowledge_sources, :price, :string
  end
end
