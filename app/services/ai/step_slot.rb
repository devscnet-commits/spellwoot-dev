# Leitura do `collect` (slot declarado) de uma etapa do playbook. Fonte ÚNICA usada tanto pelo
# Ai::StateManager (avanço determinístico + extração) quanto pelo Ai::PromptCompiler (bloco "FALTA
# agora") — evita duas leituras divergentes da mesma estrutura jsonb. Aceita as chaves em string ou
# símbolo. Uma etapa sem `collect` é informativa (sem slot).
module Ai::StepSlot
  module_function

  # Gap 1 (recusa de slot): valor SENTINELA de ausência gravado quando o cliente declina um dado de slot
  # OPCIONAL. É um TOKEN (não uma string legível de propósito — ver Ai::SlotAbsence): fica só em
  # ai_collected_facts (memória de trabalho da IA), NUNCA no espelho custom_attributes, e é mapeado para
  # ABSENT_LABEL em TODO ponto de saída (prompt, resumo de handoff). Um token falha de forma VISÍVEL se
  # vazar; uma string legível ("não informado") viraria dado indistinguível de valor real em relatório/
  # Bitrix/Meta (corrupção silenciosa).
  ABSENT = '__sem_valor__'
  ABSENT_LABEL = 'não informado'

  def absent?(value)
    value.to_s.strip == ABSENT
  end

  # Valor para EXIBIÇÃO: mapeia o token de ausência para o rótulo legível; qualquer outro valor passa.
  def display(value)
    absent?(value) ? ABSENT_LABEL : value
  end

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

  # Chave (snake_case) do dado que a etapa coleta: SÓ a DECLARADA no collect (o Select da etapa grava
  # collect['attribute']). Sem collect => nil => etapa informativa (avanço por step_completed do modelo).
  # A inferência por regex da instrução (infer + ~80 linhas de BLACKLIST/STOPWORDS) foi REMOVIDA: era
  # heurística de tenant PT-BR que adivinhava errado e deixava o slot invisível; agora a etapa DECLARA.
  def attribute(step)
    declared_attribute(step)
  end

  # Opcional? (o slot EXISTE — ver #attribute — mas a AUSÊNCIA é aceitável). Governa SÓ a regra de
  # conclusão (avança quando preenchido OU opcional-e-declinado); a CAPTURA é sempre por #attribute.
  # Precedência (Gap 2):
  #   1. collect['required'] EXPLÍCITO (não-nil) vence — compat com playbooks que declaram collect;
  #   2. senão step['slot_required'] — campo NO NÍVEL DA ETAPA (desacoplado do collect: o form grava a
  #      obrigatoriedade aqui, não em collect['required']);
  #   3. ausente => OBRIGATÓRIO (default, sem flag).
  # Substitui o antigo #required_attribute, que conflava "há slot?" (agora #attribute) com "é obrigatório?".
  def optional?(step)
    return false unless step.is_a?(Hash)

    collect = collect_of(step)
    req = collect && (collect.key?('required') ? collect['required'] : collect[:required])
    return !truthy(req) unless req.nil?

    sr = step.key?('slot_required') ? step['slot_required'] : step[:slot_required]
    return false if sr.nil?

    !truthy(sr)
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

  # (B2) Nome da ferramenta cujo RESULTADO do turno é o DOMÍNIO dinâmico deste slot (opt-in). Vazio/ausente =
  # slot comum (domínio estático ou nenhum). Configurável hoje por console/save do front (jsonb do step, não
  # strippado — to_unsafe_h); a UI do campo é pendência. Lido pelo gate (Ai::StateManager#tool_domain).
  def domain_from_tool(step)
    collect = collect_of(step)
    return nil unless collect

    (collect['domain_from_tool'] || collect[:domain_from_tool]).to_s.strip.presence
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
