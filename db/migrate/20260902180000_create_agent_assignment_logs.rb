# Log de decisão de atribuição automática: um registro por tentativa real de round-robin
# (AutoAssignment::AssignmentService#find_available_agent / AgentAssignmentService#find_assignee),
# gravando quem estava elegível, quem sobrou depois do rate limit e quem foi escolhido — hoje essa
# decisão só existe no instante em que acontece (não fica log nenhum em lugar nenhum), então não dá
# pra responder depois "a política pulou a Fulana nesse lead?" sem isso.
class CreateAgentAssignmentLogs < ActiveRecord::Migration[7.1]
  def change
    create_table :agent_assignment_logs do |t|
      t.references :account, null: false, foreign_key: true
      t.references :inbox, null: false, foreign_key: true, index: false
      t.references :conversation, null: false, foreign_key: true
      t.jsonb :eligible_agent_ids, null: false, default: []
      t.jsonb :available_agent_ids, null: false, default: []
      t.references :assigned_agent, foreign_key: { to_table: :users }
      t.timestamps
    end
    # Consulta principal: decisões desta caixa num intervalo de tempo (cobre também o filtro só por inbox).
    add_index :agent_assignment_logs, %i[inbox_id created_at]
  end
end
