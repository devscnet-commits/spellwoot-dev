class AddRoutingStrategyToAiOperationProfiles < ActiveRecord::Migration[7.1]
  def change
    add_column :ai_operation_profiles, :routing_strategy, :jsonb, null: false, default: {}
  end
end
