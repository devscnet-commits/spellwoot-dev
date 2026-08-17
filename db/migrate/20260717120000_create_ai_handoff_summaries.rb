# Resumo dedicado da conversa gerado quando a IA transfere AUTOMATICAMENTE para um humano (loop,
# crédito esgotado, handoff nativo por baixa confiança). Um registro por handoff automático — histórico
# completo por conversa; o card na sidebar mostra o mais recente. NÃO reaproveita o ai_agent_memory.summary
# (rolling) — é um resumo novo, do momento do handoff, para o atendente ler antes de entrar.
class CreateAiHandoffSummaries < ActiveRecord::Migration[7.1]
  def change
    create_table :ai_handoff_summaries do |t|
      t.references :account, null: false, foreign_key: true
      t.references :conversation, null: false, foreign_key: true, index: false
      t.references :ai_run, null: true, foreign_key: { to_table: :ai_runs }
      t.string :reason, null: false   # 'loop' | 'credit_exhausted' | 'modelo_pediu_transferencia' | 'palavra_chave'
      t.text   :content, null: false  # o resumo em si
      t.timestamps
    end
    # Busca do card: "o mais recente desta conversa" -> índice composto (cobre também o filtro por conversa).
    add_index :ai_handoff_summaries, %i[conversation_id created_at]
  end
end
