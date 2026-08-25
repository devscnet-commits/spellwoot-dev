# Índice para a purga de retenção (Ai::EventsRetentionJob) varrer por data sem seq scan.
# Concurrently p/ não travar a tabela em produção (ai_events cresce ~10x por run).
class AddIndexToAiEventsCreatedAt < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def change
    add_index :ai_events, :created_at, name: 'index_ai_events_on_created_at',
                                       algorithm: :concurrently, if_not_exists: true
  end
end
