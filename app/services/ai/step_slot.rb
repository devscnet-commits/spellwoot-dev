# Leitura do `collect` (slot declarado) de uma etapa do playbook. Fonte ÚNICA usada tanto pelo
# Ai::StateManager (avanço determinístico + extração) quanto pelo Ai::PromptCompiler (bloco "FALTA
# agora") — evita duas leituras divergentes da mesma estrutura jsonb. Aceita as chaves em string ou
# símbolo. Uma etapa sem `collect` é informativa (sem slot).
module Ai::StepSlot
  module_function

  # O hash `collect` da etapa, ou nil quando a etapa não declara coleta.
  def collect_of(step)
    return nil unless step.is_a?(Hash)

    collect = step['collect'] || step[:collect]
    collect.is_a?(Hash) ? collect : nil
  end

  # Chave (snake_case) do dado que a etapa coleta, ou nil.
  def attribute(step)
    collect = collect_of(step)
    return nil unless collect

    (collect['attribute'] || collect[:attribute]).to_s.strip.presence
  end

  # Chave do slot OBRIGATÓRIO (required só DESLIGA se vier explicitamente falso; ausente => obrigatório).
  # nil quando a etapa não coleta ou o slot é opcional — o avanço determinístico só governa slot obrigatório.
  def required_attribute(step)
    key = attribute(step)
    return nil if key.nil?

    collect = collect_of(step)
    required = collect.key?('required') ? collect['required'] : collect[:required]
    return nil if !required.nil? && !truthy(required)

    key
  end

  def type(step)
    collect = collect_of(step)
    return 'text' unless collect

    (collect['type'] || collect[:type]).to_s.strip.presence || 'text'
  end

  def options(step)
    collect = collect_of(step)
    collect ? Array(collect['options'] || collect[:options]) : []
  end

  # Critério de conclusão declarado ('attribute_present' | 'always' | ...), ou '' quando ausente.
  def criterion(step)
    return '' unless step.is_a?(Hash)

    (step['complete_when'] || step[:complete_when]).to_s.strip
  end

  def truthy(value)
    value == true || value.to_s.strip.casecmp?('true')
  end
end
