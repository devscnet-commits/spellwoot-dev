# Grupo de WhatsApp fica na aba "Grupos", fora da lista de atendimento, da distribuição automática, do CSAT e
# dos relatórios — só humanos respondem. A marca nasce na criação da conversa (Conversations::GroupDetector);
# o job marca as que já existiam.
class AddGroupChatToConversations < ActiveRecord::Migration[7.1]
  def up
    add_column :conversations, :group_chat, :boolean, default: false, null: false
    Conversation.reset_column_information
    Migration::BackfillGroupChatJob.perform_later
  end

  def down
    remove_column :conversations, :group_chat
  end
end
