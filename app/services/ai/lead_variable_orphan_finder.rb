# Uma Ai::LeadVariable "órfã": não é mais referenciada como collect.attribute em NENHUMA etapa do
# playbook ATUAL do agente (mesma definição de "em uso" que Api::V1::Accounts::
# AiLeadVariablesController#using_step_name já usa pra BLOQUEAR exclusão manual pela tela — reaproveitada
# aqui, não duplicada). Só o playbook ATUAL conta, não Ai::PlaybookVersion antigas — uma variável usada
# só numa versão histórica já é órfã pro propósito de limpeza (o histórico preserva o VALOR já coletado
# em ai_collected_facts/CustomerMemory.key_facts, não o metadado da variável em si).
module Ai::LeadVariableOrphanFinder
  module_function

  def for_agent(agent)
    used = Array(agent.playbook&.steps).flat_map { |s| Ai::StepSlot.declared_attributes(s) }.to_set
    agent.lead_variables.reject { |v| used.include?(v.name) }
  end

  def for_account(account)
    Ai::Agent.where(account_id: account.id).includes(:lead_variables, :playbook)
             .flat_map { |a| for_agent(a) }
  end

  def all
    Ai::Agent.includes(:lead_variables, :playbook).flat_map { |a| for_agent(a) }
  end
end
