# Uma Ai::LeadVariable "órfã": não é mais referenciada como collect.attribute em NENHUMA etapa do
# playbook ATUAL do department (mesma definição de "em uso" que Api::V1::Accounts::
# AiLeadVariablesController#using_step_name já usa pra BLOQUEAR exclusão manual pela tela — reaproveitada
# aqui, não duplicada). Só o playbook ATUAL conta, não Ai::PlaybookVersion antigas — uma variável usada
# só numa versão histórica já é órfã pro propósito de limpeza (o histórico preserva o VALOR já coletado
# em ai_collected_facts/CustomerMemory.key_facts, não o metadado da variável em si).
module Ai::LeadVariableOrphanFinder
  module_function

  def for_department(department)
    used = Array(department.playbook&.steps).filter_map { |s| Ai::StepSlot.attribute(s) }.to_set
    department.lead_variables.reject { |v| used.include?(v.name) }
  end

  def for_account(account)
    Ai::Department.where(account_id: account.id).includes(:lead_variables, :playbook)
                  .flat_map { |d| for_department(d) }
  end

  def all
    Ai::Department.includes(:lead_variables, :playbook).flat_map { |d| for_department(d) }
  end
end
