# Tools are always autonomous now (always 'allowed'), so the per-tool governance gate
# is gone. The audit ledger (ai_capability_executions.governance) keeps recording 'allowed'.
class RemoveGovernanceFromAiTools < ActiveRecord::Migration[7.1]
  def change
    remove_column :ai_tools, :governance, :string, null: false, default: 'allowed'
  end
end
