# Fusão Departamento -> Agente (pedido do dono da conta, 19/08): confirmado por auditoria manual
# no banco de produção que, hoje, todo agente tem no máximo 1 departamento real em uso (o único
# caso de 2 tinha um department vazio/órfão, já removido). Departamento deixa de existir como
# conceito próprio; os 5 campos abaixo (config ativa, não sobras) sobem pro Agente, e os 6 modelos
# que hoje referenciam ai_department_id passam a referenciar o Agente diretamente.
#
# NÃO migrados (confirmado morto/redundante por grep, ver auditoria): name/objetivo/instructions/
# status/is_default/position/copilot_config/auto_attendance_config de ai_departments — Agent já tem
# name/status próprios, os demais não são lidos em nenhum fluxo ativo.
#
# ai_department_inboxes NÃO ganha ai_agent_id — é usado SÓ pelo Ai::DepartmentResolver pra
# desempatar entre departamentos do MESMO agente (achado na investigação: não existe mais isso com
# 1 departamento por agente); ai_agent_inboxes já é o roteamento real inbox->agente. A tabela é
# descartada por completo, sem substituto.
#
# Additive only (esta migração). Backfill de dados e drop das colunas antigas vêm nas 2 próximas.
class AddAgentFieldsForDepartmentMerge < ActiveRecord::Migration[7.1]
  def change
    add_column :ai_agents, :sla, :jsonb, default: {}, null: false
    add_column :ai_agents, :transfer_rules, :jsonb, default: {}, null: false
    add_column :ai_agents, :close_rules, :jsonb, default: {}, null: false
    add_column :ai_agents, :behavior, :jsonb, default: {}, null: false
    add_column :ai_agents, :follow_up, :jsonb, default: {}, null: false

    # Nullability espelha a coluna ai_department_id que está substituindo em cada tabela (conferido
    # em db/structure.sql): NOT NULL onde já era obrigatório, opcional onde já permitia NULL
    # (ai_knowledge_sources/ai_tools usam NULL pra "compartilhado com a conta inteira").
    #
    # ai_runs NÃO entra aqui: já tem ai_agent_id (bigint, sem índice ainda) — o Gateway grava esse
    # campo direto do agente resolvido desde antes desta fusão (app/services/ai/gateway.rb), nunca
    # dependeu de ai_department_id. Só falta o índice.
    add_column :ai_department_integrations, :ai_agent_id, :bigint
    add_column :ai_knowledge_sources, :ai_agent_id, :bigint
    add_column :ai_lead_variables, :ai_agent_id, :bigint
    add_column :ai_playbooks, :ai_agent_id, :bigint
    add_column :ai_tools, :ai_agent_id, :bigint

    add_index :ai_department_integrations, :ai_agent_id
    add_index :ai_knowledge_sources, :ai_agent_id
    add_index :ai_lead_variables, :ai_agent_id
    add_index :ai_playbooks, :ai_agent_id
    add_index :ai_runs, :ai_agent_id
    add_index :ai_tools, :ai_agent_id
  end
end
