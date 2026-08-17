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

  # TODAS as chaves declaradas no collect (independente de required) — SEMPRE array, mesmo pra etapa
  # de 1 atributo só (Array() normaliza string OU array — collect['attribute'] aceita os dois formatos
  # desde sempre). [] quando não há collect ou o campo está vazio.
  #
  # Achado ao vivo (16/08): antes, #declared_attribute fazia `.to_s` no valor bruto — um collect.attribute
  # configurado como array (ex.: ["cidade", "viabilidade"], usado como improviso de quando o sistema só
  # aceitava 1 atributo por etapa) virava uma ÚNICA string colada '["cidade", "viabilidade"]' pro lado que
  # monta prompt/tool (Ai::PythonOrchestratorClient/Ai::StepCaptureTool), enquanto o lado que valida avanço
  # (Api::Internal::AiExecuteToolController#collect_attributes, que sempre usou Array() puro) continuava
  # exigindo as DUAS chaves reais ("cidade" e "viabilidade") separadas — a etapa nunca tinha como concluir,
  # porque a IA só recebia instrução/ferramenta pra escrever a chave colada, nunca as duas reais. Esta é
  # agora a fonte ÚNICA usada nos dois lados — sem mais leituras divergentes do mesmo campo.
  def declared_attributes(step)
    collect = collect_of(step)
    return [] unless collect

    Array(collect['attribute'] || collect[:attribute]).map { |a| a.to_s.strip }.reject(&:blank?)
  end

  # Chave ÚNICA (compat): primeira atributo declarado, ou nil. Uso só onde a etapa é conhecida como
  # single-attribute (a maioria) — código que precisa lidar com etapas de VÁRIOS atributos (prompt,
  # tools, validação de avanço) usa #declared_attributes.
  def declared_attribute(step)
    declared_attributes(step).first
  end

  # Chave (snake_case) do PRIMEIRO dado que a etapa coleta — ver #declared_attributes pra etapa com
  # mais de um. Sem collect => nil => etapa informativa (avanço por step_completed do modelo). A
  # inferência por regex da instrução (infer + ~80 linhas de BLACKLIST/STOPWORDS) foi REMOVIDA: era
  # heurística de tenant PT-BR que adivinhava errado e deixava o slot invisível; agora a etapa DECLARA.
  def attribute(step)
    declared_attribute(step)
  end

  # Etapa declara mais de 1 atributo? Governa se o prompt/ferramentas tratam type/options (que hoje só
  # existem UMA vez por etapa, não por atributo — ver #type/#options) como aplicáveis: com vários
  # atributos misturados, aplicar o MESMO type/options configurado pra todos seria errado (ex.: um enum
  # de cidades vazando pro atributo "viabilidade"), então cada atributo cai pro tipo genérico 'string'.
  def multi_attribute?(step)
    declared_attributes(step).size > 1
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
