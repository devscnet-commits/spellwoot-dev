# Allowlist for AI->AI handoff: the teams this agent may transfer a conversation to.
# When the AI decides to hand off to another sector, the target team must be in this list;
# otherwise the conversation falls back to a human. Empty = no AI->AI handoff allowed.
class AddHandoffTeamIdsToAiAgents < ActiveRecord::Migration[7.1]
  def change
    add_column :ai_agents, :handoff_team_ids, :jsonb, null: false, default: []
  end
end
