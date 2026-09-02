# Snapshot periódico de disponibilidade de agente (ver AgentPresenceSnapshotJob, roda a cada minuto),
# espelhando exatamente o mesmo sinal que a atribuição automática usa pra decidir quem está "disponível"
# (OnlineStatusTracker.get_available_users). O heartbeat em si só existe no Redis com o timestamp mais
# recente (sem histórico), então sem isso não dá pra reconstruir depois quantas horas um agente ficou
# disponível pro round-robin, nem comparar entre agentes.
class CreateAgentPresenceSnapshots < ActiveRecord::Migration[7.1]
  def change
    create_table :agent_presence_snapshots do |t|
      t.references :account, null: false, foreign_key: true, index: false
      t.references :user, null: false, foreign_key: true, index: false
      t.string :status, null: false
      t.datetime :recorded_at, null: false
    end
    # Consulta principal: quantos minutos este agente ficou em cada status, num intervalo, nesta conta.
    add_index :agent_presence_snapshots, %i[account_id user_id recorded_at],
              name: 'index_agent_presence_snapshots_on_account_user_time'
  end
end
