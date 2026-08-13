# A FK ai_handoff_summaries.conversation_id -> conversations nasceu SEM on_delete (NO ACTION):
# deletar uma conversa (ou um contato em cascata) que tinha resumo de handoff travava com
# InvalidForeignKey, deixando a conversa órfã (bug de produção no sandbox). Passa a ON DELETE CASCADE
# como defesa em profundidade no nível do banco (complementa o dependent: :delete_all no model
# Conversation, que cobre o caminho ActiveRecord).
class CascadeAiHandoffSummariesConversationFk < ActiveRecord::Migration[7.1]
  def up
    remove_foreign_key :ai_handoff_summaries, :conversations
    add_foreign_key :ai_handoff_summaries, :conversations, on_delete: :cascade
  end

  def down
    remove_foreign_key :ai_handoff_summaries, :conversations
    add_foreign_key :ai_handoff_summaries, :conversations
  end
end
