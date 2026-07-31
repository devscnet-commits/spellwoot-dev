# Dev-time helper that suggests good prompts. Given a free-text brief from the user, generates ONE
# text suggestion for either an agent base_prompt or a playbook step's instructions. Suggestion-only
# (the UI never auto-fills — the user copies if they like it). Account-scoped, but when a `department`
# is given it grounds the suggestion in that department's REAL capabilities (tools, knowledge sources,
# variables) — so it stops teaching the user to promise consultations that have no source (o bug de
# "vou verificar suas faturas" sem ferramenta). Os system prompts (texto grande) ficam em
# Ai::PromptAssistant::Prompts. Reuses Ai::ModelRouter (cheap fixed model) and records an Ai::Run for
# audit/cost — consuming the account's AI credits like every other AI call.
class Ai::PromptAssistant
  MODEL = 'gpt-4.1-mini'.freeze
  KINDS = %w[base_prompt step_instructions].freeze

  def initialize(account:, kind:, brief:, department: nil, requested_by: nil)
    @account = account
    @kind = kind.to_s
    @brief = brief.to_s
    @department = department
    @requested_by = requested_by
  end

  def suggest
    return { 'error' => 'kind inválido' } unless KINDS.include?(@kind)
    return { 'error' => 'descreva o que você quer no campo de texto' } if @brief.strip.blank?

    run = Ai::Run.create!(account_id: @account.id, run_type: 'prompt_assistant', mode: 'assistant', status: 'running')
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    # call_model (entrada LIVRE, SEM schema) — como o handoff_summary/CaptureJudge. O `decide` imporia o
    # DecisionSchema strict e a saída viraria o ENVELOPE de decisão (decision/asked_slot/proposed_value/...),
    # NUNCA o {"suggestion"} que o prompt pede (bug #302: o formato dependia de qual método chamava o modelo).
    raw = Ai::ModelRouter.call_model(
      provider: 'openai', model: MODEL,
      system_prompt: full_system_prompt, user_message: @brief, account_id: @account.id, json: true
    )
    suggestion = extract_suggestion(raw[:text])
    record_run(run, raw, suggestion, started)

    { 'suggestion' => suggestion, 'run_id' => run.id, 'status' => raw[:status] == 'error' ? 'error' : 'recorded' }
  rescue StandardError => e
    Rails.logger.error "[Ai::PromptAssistant] account=#{@account&.id} kind=#{@kind} #{e.class}: #{e.message}"
    { 'error' => "#{e.class}: #{e.message}" }
  end

  private

  # System prompt (regras estáticas por kind) + o bloco de CAPACIDADES REAIS do department. As regras
  # 7/9 (ação só com fonte) e 4 (variável do select) referenciam esse bloco por nome; sem department
  # ele degrada para um aviso honesto (nunca some — senão a regra ficaria pendurada sem o dado).
  def full_system_prompt
    [system_prompt(@kind), capabilities_block].compact.join("\n\n")
  end

  def system_prompt(kind)
    kind == 'base_prompt' ? Prompts::BASE_PROMPT_SYSTEM : Prompts::STEP_INSTRUCTIONS_SYSTEM
  end

  # Bloco que ancora o item 1 (ação sem fonte) e o item 3 (variável do select). Tools/knowledge valem
  # para os dois kinds; variáveis só interessam ao step. Sem department: contexto indisponível -> aviso.
  def capabilities_block
    return unavailable_capabilities if @department.nil?

    parts = ['CAPACIDADES REAIS DESTE AGENTE — use SÓ o que está listado aqui. Se o pedido exigir algo ' \
             'que não está nesta lista, AVISE no texto (conforme as regras) em vez de inventar.']
    parts << tools_section
    parts << knowledge_section
    parts << variables_section if @kind == 'step_instructions'
    parts.join("\n\n")
  end

  def unavailable_capabilities
    'CONTEXTO INDISPONÍVEL: não recebi a lista de ferramentas/fontes/variáveis deste agente. NÃO afirme ' \
      'que uma consulta a fonte externa (faturas, pedidos, cobertura, estoque, status) existe. Se o pedido ' \
      'envolver esse tipo de consulta, NÃO escreva a instrução de consulta — escreva no texto o aviso: ' \
      '"AVISO: verifique se existe ferramenta cadastrada para esta consulta antes de publicar."'
  end

  def tools_section
    rows = @department.tools.active.pluck(:name, :description)
    return 'Ferramentas cadastradas: NENHUMA. Não instrua nenhuma consulta/verificação via ferramenta.' if rows.empty?

    lines = rows.map { |name, desc| "- #{name}: #{desc}" }
    "Ferramentas cadastradas (as ÚNICAS consultas que o agente sabe fazer):\n#{lines.join("\n")}"
  end

  def knowledge_section
    rows = Ai::KnowledgeSource.active
                              .where(account_id: @account.id, ai_department_id: [@department.id, nil])
                              .pluck(:kind, :title)
    return 'Fontes de conhecimento cadastradas: NENHUMA.' if rows.empty?

    lines = rows.map { |kind, title| "- #{kind}: #{title}" }
    "Fontes de conhecimento cadastradas (os ÚNICOS assuntos com base real):\n#{lines.join("\n")}"
  end

  def variables_section
    lines = variable_lines
    if lines.empty?
      return 'Variáveis já cadastradas: NENHUMA. Se a etapa precisar salvar um dado, AVISE que é preciso ' \
             'criar a variável antes (o campo é um Select do que existe) — não invente um nome de chave.'
    end

    "Variáveis já cadastradas (referencie pelo nome EXATO; não invente novas):\n#{lines.join("\n")}"
  end

  # União do front (buildSlotKeyOptions): LeadVariable = memória interna; um CAD de conversation_attribute
  # com a MESMA chave sobrepõe como "aparece no painel". A chave só é selecionável se existir numa das
  # fontes — por isso o assistente referencia, não inventa.
  def variable_lines
    panel_keys = conversation_attribute_keys
    rows = internal_variable_rows(panel_keys)
    panel_keys.each { |k| rows[k] ||= 'aparece no painel' }
    rows.map { |k, meta| "- #{k} (#{meta})" }
  end

  def conversation_attribute_keys
    @account.custom_attribute_definitions.where(attribute_model: 'conversation_attribute')
            .pluck(:attribute_key).compact.map { |k| k.to_s.strip }.reject(&:blank?)
  end

  def internal_variable_rows(panel_keys)
    rows = {}
    @department.lead_variables.order(:position).pluck(:name, :var_type).each do |name, vtype|
      key = name.to_s.strip
      next if key.blank? || rows.key?(key)

      rows[key] = panel_keys.include?(key) ? 'aparece no painel' : "#{vtype}, memória interna"
    end
    rows
  end

  # call_model devolve TEXTO CRU (sem schema): extraímos o {"suggestion":...} nós mesmos (parser tolerante,
  # como o handoff_summary#extract_summary). Degrada para o texto cru quando não vier JSON.
  def extract_suggestion(text)
    str = text.to_s
    if (json = str[/\{.*\}/m])
      value = begin
        JSON.parse(json)['suggestion']
      rescue JSON::ParserError
        nil
      end
      return value.to_s if value.present?
    end
    str.strip
  end

  # call_model NÃO devolve cost/latency (o decide devolvia) — computamos aqui, como o handoff_summary, senão
  # o ai:cost_report subconta o assistente.
  def record_run(run, raw, suggestion, started)
    tin = raw[:tokens_in].to_i
    tout = raw[:tokens_out].to_i
    run.update!(
      provider: raw[:provider] || 'openai', model: raw[:model] || MODEL, tokens_in: tin, tokens_out: tout,
      cost: Ai::ModelRouter.estimate_cost(MODEL, tin, tout),
      latency_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round,
      decision: { 'suggestion' => suggestion }, status: raw[:status] == 'error' ? 'error' : 'recorded'
    )
  end
end
