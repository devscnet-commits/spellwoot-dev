# Leitura do `collect` (slot declarado) de uma etapa do playbook. Fonte ÚNICA usada tanto pelo
# Ai::StateManager (avanço determinístico + extração) quanto pelo Ai::PromptCompiler (bloco "FALTA
# agora") — evita duas leituras divergentes da mesma estrutura jsonb. Aceita as chaves em string ou
# símbolo. Uma etapa sem `collect` é informativa (sem slot).
module Ai::StepSlot
  module_function

  # PART 1 do conserto: infere o slot da INSTRUÇÃO que o usuário já escreveu, para etapas SEM collect
  # declarado (criadas antes do #259). NÃO exige criar atributo nem marcar collect na tela — deriva o
  # slot em runtime. Reconhece três formas (a cláusula de avanço tem PREFERÊNCIA):
  #   1. forma direta:  "grave/salve/guarde/registre <chave>"  (ex.: "Grave endereco_completo com ...")
  #   2. forma explícita: "... no atributo <chave>"            (ex.: "Grave o e-mail no atributo email")
  #   3. cláusula de avanço: "assim que <chave> estiver capturado/preenchido" (reforça a mesma chave)
  # Chave = token snake_case ASCII. A forma direta só aceita a chave se ela tem "_" OU vem seguida de um
  # conector (conforme|com|no|a partir) — evita capturar palavra solta. BLACKLIST barra genéricos que
  # NUNCA são chave (ex.: "personalizado" de "atributo personalizado"). Nenhum match claro => nil.
  SAVE_RE = /(?:grave|salve|guarde|registre)\s+(?:o |a |os |as |um |uma )?(?<key>[a-z][a-z0-9_]*)/i
  ATTR_RE = /\batributo\s+["']?(?<key>[a-z][a-z0-9_]*)/i
  ADVANCE_RE = /assim\s+que\s+(?:o |a )?(?<key>[a-z][a-z0-9_]*)\s+estiver\s+(?:capturad|preenchid)/i
  CONNECTOR_RE = /\A\s+(?:conforme|com|no|a\s+partir)\b/i
  # Palavras genéricas que nunca são a chave de um slot (barram o falso positivo do bug da conv 358).
  BLACKLIST = %w[personalizado atributo informacao informação dado valor resposta cliente contato
                 historico histórico].freeze

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

  # Chave inferida da instrução (só quando NÃO há collect declarado). nil se não achar padrão claro —
  # aí a etapa segue INFORMATIVA (avanço por step_completed do modelo, compat total). A cláusula de
  # avanço ("assim que X estiver ...") tem preferência (fica em 1º), depois a forma direta, depois o
  # "atributo X". Genéricos da BLACKLIST são descartados.
  def infer(step)
    return nil unless step.is_a?(Hash)
    return nil if collect_of(step)

    text = (step['instructions'] || step[:instructions]).to_s
    [advance_key(text), save_key(text), valid_key(ATTR_RE.match(text)&.[](:key))].compact.first
  end

  # "assim que <chave> estiver capturado/preenchido" — reforço/confirmação da chave (preferência).
  def advance_key(text)
    valid_key(ADVANCE_RE.match(text)&.[](:key))
  end

  # "grave/salve/... <chave>": aceita se a chave tem "_" OU vem seguida de um conector (evita palavra solta).
  def save_key(text)
    m = SAVE_RE.match(text)
    return nil unless m

    key = m[:key]
    return nil unless key.include?('_') || text[m.end(:key)..].to_s.match?(CONNECTOR_RE)

    valid_key(key)
  end

  # Normaliza a caixa; nil se vazio ou se cair numa palavra genérica da BLACKLIST.
  def valid_key(key)
    return nil if key.nil?

    k = key.downcase
    BLACKLIST.include?(k) ? nil : k
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
