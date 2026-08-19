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

  # Multi-dado por etapa (cada um com SEU PRÓPRIO type/options/required/hint — "DADOS PARA COLETA NA
  # ETAPA" na tela): fonte ÚNICA que todo o resto do módulo (e os métodos singulares abaixo, mantidos
  # por compat com ~15 call sites que só conhecem "a etapa tem 1 slot") usa por baixo. Normaliza os
  # DOIS formatos de `collect` pra uma lista de items, cada um sempre com as MESMAS 6 chaves (string):
  #   'attribute', 'type', 'options' (array), 'domain_from_tool', 'required' (boolean), 'hint'.
  #
  #   NOVO:    collect: { items: [ {attribute:, type:, options:, domain_from_tool:, required:, hint:}, ... ] }
  #   ANTIGO:  collect: { attribute:, type:, options:, domain_from_tool:, required: }  (attribute aceita
  #            string OU array desde sempre — ver o achado 16/08 abaixo; vira N items comparTILHANDO o
  #            MESMO type/options/domain_from_tool/required, exatamente como já era lido).
  #
  # [] quando não há collect (etapa informativa) ou nenhum attribute sobrevive ao strip/reject blank.
  def items(step)
    collect = collect_of(step)
    return [] unless collect

    raw_items = collect['items'] || collect[:items]
    return items_from_list(raw_items) if raw_items.is_a?(Array)

    items_from_legacy_collect(collect, step)
  end

  # TODAS as chaves declaradas (independente de required) — SEMPRE array, mesmo pra etapa de 1 dado só.
  #
  # Achado ao vivo (16/08): antes, #declared_attribute fazia `.to_s` no valor bruto — um collect.attribute
  # configurado como array (ex.: ["cidade", "viabilidade"], usado como improviso de quando o sistema só
  # aceitava 1 atributo por etapa) virava uma ÚNICA string colada '["cidade", "viabilidade"]' pro lado que
  # monta prompt/tool (Ai::PythonOrchestratorClient/Ai::StepCaptureTool), enquanto o lado que valida avanço
  # continuava exigindo as DUAS chaves reais separadas — a etapa nunca tinha como concluir, porque a IA só
  # recebia instrução/ferramenta pra escrever a chave colada, nunca as duas reais. #items acima é agora a
  # fonte ÚNICA usada em todo lugar (inclusive Api::Internal::AiExecuteToolController, que antes lia
  # `step.dig('collect', 'attribute')` direto e ficaria cego pro formato NOVO) — sem mais leituras
  # divergentes do mesmo campo.
  def declared_attributes(step)
    items(step).map { |item| item['attribute'] }
  end

  # Chave ÚNICA (compat): primeiro atributo declarado, ou nil. Uso só onde a etapa é conhecida como
  # single-attribute (a maioria) — código que precisa lidar com etapas de VÁRIOS atributos (prompt,
  # tools, validação de avanço) usa #declared_attributes ou #items.
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

  # Etapa declara mais de 1 atributo?
  def multi_attribute?(step)
    declared_attributes(step).size > 1
  end

  # ---- Métodos SINGULARES (compat) ----
  # Leem o PRIMEIRO item de #items — byte-idêntico ao comportamento antigo pra etapa de 1 dado (a
  # esmagadora maioria dos playbooks e todo caller que só conhece "a etapa tem 1 slot": StateManager,
  # TurnCapture, SlotCollector, StepResolver, TrivialTurnGate, PromptCompiler). Numa etapa NOVA de vários
  # dados (collect.items[]), degradam graciosamente pro primeiro item declarado — quem precisa do type/
  # options/required/hint de CADA dado usa #items diretamente (Ai::PythonOrchestratorClient,
  # Api::Internal::AiExecuteToolController).

  # Opcional? (o slot EXISTE — ver #attribute — mas a AUSÊNCIA é aceitável). Governa SÓ a regra de
  # conclusão (avança quando preenchido OU opcional-e-declinado); a CAPTURA é sempre por #attribute.
  def optional?(step)
    item = items(step).first
    item ? !item['required'] : false
  end

  def type(step)
    items(step).first&.fetch('type', 'text') || 'text'
  end

  def options(step)
    items(step).first&.fetch('options', []) || []
  end

  # (B2) Nome da ferramenta cujo RESULTADO do turno é o DOMÍNIO dinâmico deste slot (opt-in). Vazio/ausente =
  # slot comum (domínio estático ou nenhum). Lido pelo gate (Ai::StateManager#tool_domain).
  def domain_from_tool(step)
    items(step).first&.fetch('domain_from_tool', nil)
  end

  # Critério de conclusão declarado ('attribute_present' | 'always' | ...), ou '' quando ausente.
  def criterion(step)
    return '' unless step.is_a?(Hash)

    (step['complete_when'] || step[:complete_when]).to_s.strip
  end

  def truthy(value)
    value == true || value.to_s.strip.casecmp?('true')
  end

  # ---- normalização interna (privado de fato, só não usa `private` pq module_function já cobre) ----

  def items_from_list(raw_items)
    raw_items.filter_map { |raw| normalize_item(raw) }
  end

  def normalize_item(raw)
    return nil unless raw.is_a?(Hash)

    attribute = (raw['attribute'] || raw[:attribute]).to_s.strip
    return nil if attribute.blank?

    required = raw.key?('required') ? raw['required'] : raw[:required]
    hint = (raw['hint'] || raw[:hint]).to_s.strip

    {
      'attribute' => attribute,
      'type' => (raw['type'] || raw[:type]).to_s.strip.presence || 'text',
      'options' => Array(raw['options'] || raw[:options]),
      'domain_from_tool' => (raw['domain_from_tool'] || raw[:domain_from_tool]).to_s.strip.presence,
      # ausente => OBRIGATÓRIO (mesmo default do formato antigo — ver #legacy_required).
      'required' => required.nil? || truthy(required),
      'hint' => hint.presence
    }
  end

  # Formato ANTIGO: 1 `collect` por etapa, `attribute` string OU array, type/options/domain_from_tool/
  # required COMPARTILHADOS por todos os atributos declarados (era exatamente assim que já funcionava
  # antes de #items existir — nenhuma mudança de comportamento pra playbook já salvo).
  def items_from_legacy_collect(collect, step)
    attributes = Array(collect['attribute'] || collect[:attribute]).map { |a| a.to_s.strip }.reject(&:blank?)
    return [] if attributes.empty?

    type = (collect['type'] || collect[:type]).to_s.strip.presence || 'text'
    options = Array(collect['options'] || collect[:options])
    domain_from_tool = (collect['domain_from_tool'] || collect[:domain_from_tool]).to_s.strip.presence
    required = legacy_required(collect, step)

    attributes.map do |attribute|
      { 'attribute' => attribute, 'type' => type, 'options' => options,
        'domain_from_tool' => domain_from_tool, 'required' => required, 'hint' => nil }
    end
  end

  # Precedência (Gap 2), preservada byte-a-byte do antigo #optional?:
  #   1. collect['required'] EXPLÍCITO (não-nil) vence — compat com playbooks que declaram collect;
  #   2. senão step['slot_required'] — campo NO NÍVEL DA ETAPA (desacoplado do collect: o form antigo
  #      grava a obrigatoriedade aqui, não em collect['required']);
  #   3. ausente => OBRIGATÓRIO (default, sem flag).
  # Só vale pro formato ANTIGO — o formato NOVO carrega 'required' por item, sem indireção nenhuma
  # (ver #normalize_item).
  def legacy_required(collect, step)
    req = collect.key?('required') ? collect['required'] : collect[:required]
    return truthy(req) unless req.nil?

    sr = step.is_a?(Hash) ? (step.key?('slot_required') ? step['slot_required'] : step[:slot_required]) : nil
    return true if sr.nil?

    truthy(sr)
  end
end
