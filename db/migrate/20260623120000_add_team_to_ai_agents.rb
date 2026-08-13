# Routing among specialized agents that share an inbox: an agent linked to a team handles
# conversations assigned to that team (via Chatwoot's existing assignment rules). Team-less
# agents attend any conversation on their inboxes.
class AddTeamToAiAgents < ActiveRecord::Migration[7.1]
  def change
    add_column :ai_agents, :team_id, :bigint
    add_index :ai_agents, :team_id
  end
end
