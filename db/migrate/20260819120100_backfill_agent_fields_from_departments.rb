# Fusão Departamento -> Agente, passo 2/3: copia os dados reais (não as colunas mortas, ver
# migração anterior) de ai_departments pro Agente dono, e aponta os 6 modelos dependentes
# direto pro agente. down apaga só o que esta migração escreveu (as colunas antigas ai_department_id
# continuam intactas até a migração de limpeza final).
class BackfillAgentFieldsFromDepartments < ActiveRecord::Migration[7.1]
  def up
    execute <<~SQL.squish
      UPDATE ai_agents a
      SET sla = d.sla, transfer_rules = d.transfer_rules, close_rules = d.close_rules,
          behavior = d.behavior, follow_up = d.follow_up
      FROM ai_departments d
      WHERE d.ai_agent_id = a.id
    SQL

    # ai_runs fica de fora: ai_agent_id já vem populado direto pelo Gateway desde antes desta fusão,
    # nunca dependeu de ai_department_id (ver comentário na migração anterior).
    %w[ai_department_integrations ai_knowledge_sources ai_lead_variables ai_playbooks ai_tools].each do |table|
      execute <<~SQL.squish
        UPDATE #{table} t
        SET ai_agent_id = d.ai_agent_id
        FROM ai_departments d
        WHERE t.ai_department_id = d.id
      SQL
    end
  end

  def down
    execute 'UPDATE ai_agents SET sla = \'{}\', transfer_rules = \'{}\', close_rules = \'{}\', behavior = \'{}\', follow_up = \'{}\''

    %w[ai_department_integrations ai_knowledge_sources ai_lead_variables ai_playbooks ai_tools].each do |table|
      execute "UPDATE #{table} SET ai_agent_id = NULL"
    end
  end
end
