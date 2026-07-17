# Leitura do `collect` (slot declarado) de uma etapa do playbook. Fonte ÚNICA usada tanto pelo
# Ai::StateManager (avanço determinístico + extração) quanto pelo Ai::PromptCompiler (bloco "FALTA
# agora") — evita duas leituras divergentes da mesma estrutura jsonb. Aceita as chaves em string ou
# símbolo. Uma etapa sem `collect` é informativa (sem slot).
module Ai::StepSlot
  module_function

  # PART 1 do conserto: infere o slot da INSTRUÇÃO que o usuário já escreveu, para etapas SEM collect
  # declarado (criadas antes do #259). Âncora no termo "atributo" seguido de uma chave snake_case ASCII
  # (o formato que o PromptAssistant recomenda), ex.: "grave o e-mail no atributo email". Ancorar em
  # "atributo" é conservador — evita falso positivo. NÃO exige que o usuário crie atributo nem marque
  # collect na tela: o sistema deriva o slot em tempo de execução.
  INFER_RE = /\batributo\s+["']?(?<key>[a-z][a-z0-9_]*)/i

  # O hash `collect` da etapa, ou nil quando a etapa não declara coleta.
  def collect_of(step)
    return nil unless step.is_a?(Hash)

    collect = step['collect'] || step[:collect]
    collect.is_a?(Hash) ? collect : nil
  end

  # Chave declarada no collect (independente de required), ou nil.
  def declared_attribute(step)
    collect = collect_of(step)
    return nil unless collect

    (collect['attribute'] || collect[:attribute]).to_s.strip.presence
  end

  # Chave inferida da instrução (só quando NÃO há collect declarado). nil se não achar o padrão —
  # aí a etapa segue INFORMATIVA (avanço por step_completed do modelo, compat total).
  def infer(step)
    return nil unless step.is_a?(Hash)
    return nil if collect_of(step)

    m = INFER_RE.match((step['instructions'] || step[:instructions]).to_s)
    m && m[:key].downcase
  end

  # Chave (snake_case) do dado que a etapa coleta: DECLARADA (collect) OU INFERIDA da instrução.
  def attribute(step)
    declared_attribute(step) || infer(step)
  end

  # Chave do slot OBRIGATÓRIO (required só DESLIGA se vier explicitamente falso; ausente => obrigatório).
  # O slot INFERIDO é sempre coleta obrigatória. nil quando a etapa não coleta ou o slot declarado é
  # opcional — o avanço determinístico só governa slot obrigatório.
  def required_attribute(step)
    declared = declared_attribute(step)
    return infer(step) if declared.nil?

    optional?(step) ? nil : declared
  end

  # collect declarado com required explicitamente falso.
  def optional?(step)
    collect = collect_of(step)
    return false unless collect

    required = collect.key?('required') ? collect['required'] : collect[:required]
    !required.nil? && !truthy(required)
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
