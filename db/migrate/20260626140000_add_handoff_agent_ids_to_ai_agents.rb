# Allowlist de transferência IA->IA por agente específico (além de handoff_team_ids).
# Lista de ids de Ai::Agent para os quais este agente pode transferir a conversa.
class AddHandoffAgentIdsToAiAgents < ActiveRecord::Migration[7.1]
  def change
    add_column :ai_agents, :handoff_agent_ids, :jsonb, null: false, default: []
  end
end
