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

  # PART 1 do conserto: infere o slot da INSTRUÇÃO que o usuário já escreveu, para etapas SEM collect
  # declarado (criadas antes do #259). NÃO exige criar atributo nem marcar collect na tela — deriva o
  # slot em runtime. Reconhece três formas (a cláusula de avanço tem PREFERÊNCIA, depois "atributo X",
  # depois a forma direta):
  #   1. cláusula de avanço: "assim que <chave> estiver capturado/preenchido"
  #   2. explícita: "...no atributo <chave>"  (ex.: "Grave o e-mail no atributo email")
  #   3. direta:    "grave/salve/guarde/registre <chave>"  (ex.: "Grave endereco_completo com ...")
  # Ao escanear, PULA palavras genéricas (BLACKLIST: advérbios/adjetivos/rótulos como "imediatamente",
  # "customizado", "personalizado") e stopwords (artigos/preposições), continuando até a chave REAL na
  # mesma frase — e PREFERE a chave com "_". A forma direta só aceita a chave se tem "_" OU vem seguida
  # de um conector (evita palavra solta). Nenhum candidato plausível => nil (etapa informativa).
  SAVE_VERB_RE = /\b(?:grave|salve|guarde|registre)\b/i
  ATTR_ANCHOR_RE = /\batributo\b/i
  ADVANCE_RE = /assim\s+que\s+(?:o |a )?(?<key>[a-z][a-z0-9_]*)\s+estiver\s+(?:capturad|preenchid)/i
  CONNECTOR_TOKEN_RE = /([a-z][a-z0-9_]*)\s+(?:conforme|com|no|a\s+partir)\b/i
  KEY_TOKEN_RE = /[a-z][a-z0-9_]*/i
  SENTENCE_HEAD_RE = /\A[^.!?\n]*/ # até o fim da frase (não cruza para a próxima)
  # Genéricos que NUNCA são a chave de um slot (advérbios/adjetivos/rótulos + o falso positivo da conv 358).
  BLACKLIST = %w[personalizado customizado atributo imediatamente novamente corretamente sempre apenas
                 somente exatamente informacao informação dado valor resposta cliente contato historico
                 histórico].freeze
  # Artigos/preposições/conjunções que aparecem no meio da frase e nunca são chave.
  STOPWORDS = %w[o a os as um uma uns umas de do da dos das no na nos nas em ao aos com por para pra e
                 ou que se seu sua seus suas].freeze

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
  # aí a etapa segue INFORMATIVA (avanço por step_completed do modelo, compat total).
  def infer(step)
    return nil unless step.is_a?(Hash)
    return nil if collect_of(step)

    text = (step['instructions'] || step[:instructions]).to_s
    [advance_key(text), attr_key(text), grave_key(text)].compact.first
  end

  # "assim que <chave> estiver capturado/preenchido" — reforço/confirmação da chave (preferência).
  def advance_key(text)
    m = ADVANCE_RE.match(text)
    m && usable_key(m[:key])
  end

  # "...atributo <chave>": pula genéricos/stopwords logo após "atributo" (ex.: "atributo personalizado
  # cidade" -> "cidade"; "atributo customizado periodo_reservado" -> "periodo_reservado") e prefere "_".
  def attr_key(text)
    m = ATTR_ANCHOR_RE.match(text)
    return nil unless m

    best_key(sentence_tokens(text, m.end(0)))
  end

  # Forma direta "grave <chave>": a 1ª chave com "_" na frase (pulando genéricos); senão a 1ª chave
  # (não genérica) SEGUIDA de um conector. Sem "_" e sem conector => nil (conservador).
  def grave_key(text)
    m = SAVE_VERB_RE.match(text)
    return nil unless m

    seg = text[m.end(0)..].to_s[SENTENCE_HEAD_RE]
    underscore_key(seg) || connector_key(seg)
  end

  # 1ª chave com "_" (não genérica) na frase.
  def underscore_key(seg)
    seg.scan(KEY_TOKEN_RE).map(&:downcase).find { |t| t.include?('_') && usable?(t) }
  end

  # 1ª chave (não genérica) SEGUIDA de um conector (conforme|com|no|a partir).
  def connector_key(seg)
    seg.scan(CONNECTOR_TOKEN_RE).each { |(tok)| return tok.downcase if usable?(tok) }
    nil
  end

  # Tokens snake_case da frase a partir de `from` (para no fim da frase — não cruza para a próxima).
  def sentence_tokens(text, from)
    text[from..].to_s[SENTENCE_HEAD_RE].scan(KEY_TOKEN_RE).map(&:downcase)
  end

  # Melhor chave entre os tokens: prefere a que tem "_"; senão a 1ª usável. Descarta genéricos/stopwords.
  def best_key(tokens)
    usable = tokens.select { |t| usable?(t) }
    usable.find { |t| t.include?('_') } || usable.first
  end

  # Token pode ser chave? não vazio, não genérico (BLACKLIST) e não stopword.
  def usable?(token)
    t = token.to_s.downcase
    t.present? && BLACKLIST.exclude?(t) && STOPWORDS.exclude?(t)
  end

  def usable_key(key)
    k = key.to_s.downcase
    usable?(k) ? k : nil
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
