# Achado ao vivo pelo usuário: "plano_escolhido"/"registrar_plano_escolhido" e "viabilidade"/
# "registrar_viabilidade" — pares onde uma variável/atributo nasceu com o prefixo reservado
# "registrar_" (Ai::StepCaptureTool::PREFIX, do design ANTIGO de function-calling) grudado no nome,
# como se o prefixo fosse parte do DADO em vez do nome da tool — duplicando o que já existia sem o
# prefixo. Varre Ai::LeadVariable (escopo: agent) e CustomAttributeDefinition (escopo: conta +
# attribute_model) separadamente — são dois "espaços de nome" diferentes, uma duplicata não cruza os
# dois. Só identifica — nenhum destes métodos apaga nada.
module Ai::VariableDuplicateFinder
  REGISTRAR_PREFIX = 'registrar_'.freeze

  module_function

  # [{ agent_id:, base: <name>, base_id:, duplicate: <name>, duplicate_id: }]
  def lead_variable_duplicates
    Ai::LeadVariable.all.group_by(&:ai_agent_id).flat_map do |agent_id, vars|
      by_name = vars.index_by(&:name)
      vars.filter_map do |v|
        next unless v.name.start_with?(REGISTRAR_PREFIX)

        base = by_name[v.name.delete_prefix(REGISTRAR_PREFIX)]
        next unless base

        { agent_id: agent_id, base: base.name, base_id: base.id, duplicate: v.name, duplicate_id: v.id }
      end
    end
  end

  # [{ account_id:, attribute_model:, base: <key>, base_id:, duplicate: <key>, duplicate_id: }]
  def custom_attribute_duplicates
    CustomAttributeDefinition.all.group_by { |d| [d.account_id, d.attribute_model] }.flat_map do |(account_id, model), defs|
      by_key = defs.index_by(&:attribute_key)
      defs.filter_map do |d|
        next unless d.attribute_key.to_s.start_with?(REGISTRAR_PREFIX)

        base = by_key[d.attribute_key.delete_prefix(REGISTRAR_PREFIX)]
        next unless base

        { account_id: account_id, attribute_model: model, base: base.attribute_key, base_id: base.id,
          duplicate: d.attribute_key, duplicate_id: d.id }
      end
    end
  end
end
