# Sem IA live nem bot vinculado, uma conversa nova não tem pra qual time cair — isso dependia de
# automação externa (n8n + Bitrix) que pode estar desligada, deixando a conversa sem team_id e fora
# da distribuição automática entre agentes. Coluna soft (irmã de ai_agents.fallback_handoff_team_id),
# sem FK: validada em Conversation#assign_default_team_from_inbox.
class AddDefaultTeamIdToInboxes < ActiveRecord::Migration[7.1]
  def change
    add_column :inboxes, :default_team_id, :bigint
  end
end
