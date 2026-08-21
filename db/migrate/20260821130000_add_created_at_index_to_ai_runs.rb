# Achado ao vivo (21/08): a tela "Análises com IA" (Api::V1::Accounts::AiShadowRunsController) e
# "Custos de IA" (AiCostsController) filtram ai_runs por (account_id, período), mas só existiam
# índices soltos em conversation_id/account_id/ai_department_id/inbox_id/ai_agent_id — nenhum cobrindo
# created_at. Toda consulta por período varria o resultado inteiro do account_id sem atalho. Composto
# (não dois soltos) porque as duas telas SEMPRE filtram os dois juntos. Concurrently, mesmo padrão de
# 20260707120000_add_index_to_ai_events_created_at.rb — ai_runs cresce 1 linha por turno de IA, em
# toda conta, não pode travar a tabela num ALTER TABLE bloqueante em produção.
class AddCreatedAtIndexToAiRuns < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def change
    add_index :ai_runs, %i[account_id created_at], algorithm: :concurrently, if_not_exists: true
  end
end
