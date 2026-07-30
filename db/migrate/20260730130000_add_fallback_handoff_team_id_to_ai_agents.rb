# Motivo 3 do handoff (a IA falhou / desistiu): default de time declarado NO AGENTE, em vez do acidente de
# ordenação (1º da whitelist). Coluna discreta, irmã de team_id (bigint) — DISTINTA de team_id, que é o
# override deliberadamente intocado. nil => comportamento atual (1º da whitelist). Valida contra a whitelist
# (handoff_team_ids) na escrita (modelo) e na leitura (HandoffCoordinator).
class AddFallbackHandoffTeamIdToAiAgents < ActiveRecord::Migration[7.1]
  def change
    add_column :ai_agents, :fallback_handoff_team_id, :bigint
  end
end
