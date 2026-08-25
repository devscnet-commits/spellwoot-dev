# Shadow intelligence panel — read-only analysis of AI Core runs for the continuous-improvement
# loop (evaluate -> find gap -> fix FAQ/instruction/tool -> measure again). Derives, per run, how
# the AI resolved (knowledge / instruction / tool / transfer / closed / unanswered / error) and
# rolls that up into KPIs, diagnostic blocks and actionable insights. Reuses existing data only.
class Api::V1::Accounts::AiShadowRunsController < Api::V1::Accounts::BaseController
  LOW_CONFIDENCE = 0.5
  RECURRING_ERROR_MIN = 2
  # Teto de segurança absoluto de linhas carregadas em memória (resumo/insights são em Ruby).
  # A janela de no máx. 1 ano é a proteção principal; este é só um último anteparo contra OOM.
  MAX_RUNS = 10_000
  MAX_WINDOW_DAYS = 365
  DEFAULT_PER_PAGE = 10
  MAX_PER_PAGE = 100
  EXAMPLES_PER_INSIGHT = 25

  # Knowledge-gap noise filter: only a substantive customer question counts as a gap. Drops
  # attachment placeholders, very short messages, and greetings/acknowledgements.
  MIN_GAP_LENGTH = 10
  ATTACHMENT_PLACEHOLDERS = ['[document]', '[image]', '[audio]', '[video]'].freeze
  # Stems of greetings/thanks/acks — matched only when the message is essentially just this (<= 2
  # words), collapsing 3+ repeated letters so "obrigadaaaa" still matches "obrigad".
  GREETING_STEMS = %w[
    obrigad valeu vlw oi ola olá oie bomdia boatarde boanoite tchau ok okay blz beleza sim nao não certo
  ].freeze

  # Achado ao vivo (21/08): antes, TODA visita carregava até MAX_RUNS (10 mil) linhas pra memória do
  # Ruby e só DEPOIS cortava a página com .slice — o comentário original já admitia isso era "último
  # anteparo contra OOM", ou seja, o autor sabia que ia bater nesse teto. Agora a LISTA (as `page_rows`
  # exibidas) usa paginação de banco de verdade (LIMIT/OFFSET numa scope filtrada e indexada) — só
  # classifica (agent/tool/pergunta) as `per_page` linhas da página atual, não a janela inteira.
  # Resumo/insights continuam precisando OLHAR A JANELA INTEIRA (resolução, lacuna de conhecimento etc.
  # são calculados por linha, em Ruby, sobre decision jsonb + texto da pergunta) — isso não muda aqui;
  # o que muda é que o resultado fica em cache por alguns minutos, então navegar entre páginas do MESMO
  # filtro não repete o scan completo a cada clique. Persistir a classificação NO MOMENTO DO RUN (pra
  # virar um GROUP BY de verdade) é o próximo passo, fora do escopo deste fix pontual.
  def index
    bounds = window_bounds
    if bounds == :too_large
      return render(
        json: { error: 'range_too_large', max_days: MAX_WINDOW_DAYS },
        status: :unprocessable_entity
      )
    end

    start_time, finish_time = bounds
    base = ::Ai::Run.where(account_id: Current.account.id)
                    .where(created_at: start_time..finish_time)
    scope = filtered(base)

    page, per_page = pagination_params
    total = scope.count
    page_runs = scope.order(created_at: :desc).offset((page - 1) * per_page).limit(per_page).to_a
    page_rows = rows_for(page_runs)

    summary_data = Rails.cache.fetch(summary_cache_key(start_time, finish_time), expires_in: 2.minutes) do
      window_runs = scope.order(created_at: :desc).limit(MAX_RUNS).to_a
      window_rows = rows_for(window_runs)
      { summary: summary(window_rows), insights: insights(window_rows) }
    end

    render json: {
      facets: facets(base),
      summary: summary_data[:summary],
      insights: summary_data[:insights],
      runs: page_rows,
      pagination: {
        page: page,
        per_page: per_page,
        total: total,
        total_pages: [(total.to_f / per_page).ceil, 1].max
      }
    }
  end

  private

  # page (>=1) e per_page (limitado a MAX_PER_PAGE) para a paginação real da lista de execuções.
  # O resumo/insights continuam calculados sobre toda a janela do período, não sobre a página.
  def pagination_params
    page = params[:page].to_i
    page = 1 if page < 1
    per_page = params[:per_page].to_i
    per_page = DEFAULT_PER_PAGE if per_page < 1
    per_page = MAX_PER_PAGE if per_page > MAX_PER_PAGE
    [page, per_page]
  end

  # Janela de datas efetiva: custom (from/to) tem prioridade, senão ?days=N, senão "Todos".
  # Como métricas e lista cobrem o período inteiro, limitamos a 1 ano: acima disso devolve
  # :too_large (o front pede um intervalo menor). "Todos"/sem início = último 1 ano.
  def window_bounds
    from = parse_date(params[:from])
    to = parse_date(params[:to])
    days = params[:days].to_i

    end_date = to || Date.current
    start_date =
      if from
        from
      elsif days.positive?
        days.days.ago.to_date
      end

    return :too_large if start_date && (end_date - start_date).to_i > MAX_WINDOW_DAYS

    start_date ||= end_date - MAX_WINDOW_DAYS
    [start_date.beginning_of_day, end_date.end_of_day]
  end

  def parse_date(value)
    return nil if value.blank?

    Date.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  # has_reply/has_tool viviam como filtro em RUBY, depois de carregar a janela inteira — sem isso a
  # paginação teria que ler tudo pra saber quantas linhas passam no filtro antes de cortar a página.
  # decision->>'reply_text'/decision#>>'{tool,name}' são as MESMAS chaves que #reply_text/#tool_name
  # leem embaixo — só reescritas como predicado SQL sobre o jsonb.
  def filtered(scope)
    scope = scope.where(ai_agent_id: params[:agent_id]) if params[:agent_id].present?
    scope = scope.where(error_type: params[:error_type]) if params[:error_type].present?
    scope = scope.where(status: params[:status]) if params[:status].present?
    scope = scope.where(conversation_id: params[:conversation_id]) if params[:conversation_id].present?
    scope = scope.where("COALESCE(decision->>'reply_text', '') != ''") if params[:has_reply] == 'true'
    scope = scope.where("COALESCE(decision->>'reply_text', '') = ''") if params[:has_reply] == 'false'
    scope = scope.where("COALESCE(decision#>>'{tool,name}', '') != ''") if params[:has_tool] == 'true'
    scope = scope.where("COALESCE(decision#>>'{tool,name}', '') = ''") if params[:has_tool] == 'false'
    scope
  end

  # Chave do cache do resumo/insights (a janela inteira, não a página) — precisa refletir TODO filtro
  # que muda quais runs entram na conta, senão dois filtros diferentes leem o resumo um do outro.
  def summary_cache_key(start_time, finish_time)
    filters = params.slice(:agent_id, :error_type, :status, :conversation_id, :has_reply, :has_tool)
                    .to_unsafe_h.sort.to_h
    "ai_shadow_runs_summary/#{Current.account.id}/#{start_time.to_i}-#{finish_time.to_i}/#{filters}"
  end

  # Monta as linhas exibidas/classificadas para um conjunto de runs (a página atual, OU a janela
  # inteira pro resumo/insights) — os lookups em lote (nome do agente, ferramentas, pergunta do
  # cliente) são escopados só a ESTE conjunto, nunca a mais do que o necessário.
  def rows_for(runs)
    return [] if runs.empty?

    names = agent_names(runs)
    tools = agent_tools(runs)
    questions = questions_for(runs)
    runs.map { |run| row(run, names, tools, questions) }
  end

  # Nomes de controle RESERVADOS (avancar_etapa/registrar_*/salvar_memoria_ia/continuar_conversa/
  # conversation.resolve/conversation.transfer) — nunca foram, e nunca serão, uma Ai::Tool
  # configurável pelo admin (Api::Internal::AiExecuteToolController os reconhece por nome fixo, não
  # por cadastro). Só podem aparecer aqui em Ai::Run de ANTES da migração pro Structured Outputs
  # (17/08), quando o motor Ruby legado oferecia alguns deles como function-calling de verdade — ver
  # docs/ai-shadow-analysis-module-assessment.md §3. Marcá-los como "ferramenta ausente" pede pro
  # admin configurar algo que não é configurável; exclui sempre, independente da data do run.
  RESERVED_TOOL_NAMES = [
    Ai::PythonOrchestratorClient::ADVANCE_STEP_TOOL, Ai::PythonOrchestratorClient::RESOLVE_TOOL,
    Ai::PythonOrchestratorClient::TRANSFER_TOOL, Ai::PythonOrchestratorClient::CONTINUE_TOOL,
    Ai::PythonOrchestratorClient::MEMORY_TOOL
  ].freeze

  def row(run, agent_names, agent_tools, questions)
    tool = tool_name(run)
    missing = tool.present? && RESERVED_TOOL_NAMES.exclude?(tool) &&
              !agent_tools[run.ai_agent_id].to_a.include?(tool.downcase)
    {
      id: run.id,
      conversation_id: run.conversation_id,
      question: questions.dig(run.id, :text),
      question_message_id: questions.dig(run.id, :message_id),
      agent_id: run.ai_agent_id,
      agent: agent_names[run.ai_agent_id],
      resolution: classify(run),
      status: run.status,
      error_type: run.error_type,
      latency_ms: run.latency_ms,
      cost: run.cost,
      reply_text: reply_text(run).to_s.first(400),
      tool: tool,
      tool_missing: missing,
      knowledge_count: run.knowledge_count,
      confidence: confidence(run),
      created_at: run.created_at
    }
  end

  # How the AI resolved this run, from the persisted decision + run fields.
  def classify(run)
    return 'error' if run.error_type.present? || run.status == 'error'

    kind = (run.decision || {})['decision']
    return 'transfer' if kind == 'handoff'
    return 'closed' if kind == 'close'
    return 'tool' if kind == 'invoke_tool' || tool_name(run).present?

    if kind == 'reply' && reply_text(run).present?
      return run.knowledge_count.to_i.positive? ? 'knowledge' : 'instruction'
    end

    'unanswered'
  end

  def reply_text(run)
    (run.decision || {})['reply_text']
  end

  def tool_name(run)
    (run.decision || {}).dig('tool', 'name')
  end

  def confidence(run)
    value = (run.decision || {})['confidence']
    value.is_a?(Numeric) ? value : nil
  end

  def low_confidence?(row)
    row[:confidence] && row[:confidence] < LOW_CONFIDENCE && %w[knowledge instruction].include?(row[:resolution])
  end

  # A knowledge gap is a genuinely UNANSWERED run whose customer message is a substantive question.
  # 'instruction' (an answered reply that just didn't use RAG) is NOT a gap — it stays visible in the
  # resolution distribution, but no longer inflates the gap count/list with false positives.
  def knowledge_gap?(row)
    row[:resolution] == 'unanswered' && substantive_question?(row[:question])
  end

  # Drops attachment placeholders, very short messages and greetings/acks (Bug 2 noise filter).
  def substantive_question?(text)
    stripped = text.to_s.strip
    return false if stripped.empty?
    return false if ATTACHMENT_PLACEHOLDERS.include?(stripped.downcase)
    return false if stripped.length < MIN_GAP_LENGTH

    !greeting_only?(stripped.downcase)
  end

  # True when the message is essentially just a greeting/ack: <= 2 words matching a stem after
  # collapsing 3+ repeated letters. So "obrigadaaaa" / "bom dia!" / "okk" are dropped, but a real
  # question that only STARTS with "obrigada, ..." (3+ words) is kept.
  def greeting_only?(text)
    words = text.gsub(/[[:punct:]]/, ' ').split
    return false if words.empty? || words.size > 2

    stem = words.join.gsub(/(.)\1{2,}/, '\1')
    GREETING_STEMS.any? { |g| stem.start_with?(g) }
  end

  def summary(rows)
    by_resolution = rows.group_by { |r| r[:resolution] }.transform_values(&:size)
    {
      evaluated: rows.size,
      unanswered: by_resolution['unanswered'].to_i,
      errors: rows.count { |r| r[:error_type].present? },
      low_confidence: rows.count { |r| low_confidence?(r) },
      tools_suggested: rows.count { |r| r[:tool].present? },
      tools_missing: rows.count { |r| r[:tool_missing] },
      knowledge_gaps: rows.count { |r| knowledge_gap?(r) },
      by_resolution: by_resolution,
      by_agent: by_agent(rows),
      by_error: rows.select { |r| r[:error_type].present? }
                    .group_by { |r| r[:error_type] }.transform_values(&:size)
                    .map { |error_type, count| { error_type: error_type, count: count } }
                    .sort_by { |e| -e[:count] }
    }
  end

  def by_agent(rows)
    rows.select { |r| r[:agent].present? }.group_by { |r| r[:agent] }.map do |name, group|
      { name: name, total: group.size, errors: group.count { |r| r[:error_type].present? },
        unanswered: group.count { |r| r[:resolution] == 'unanswered' } }
    end.sort_by { |d| -d[:errors] }
  end

  # Practical "what to fix" reading: FAQ / instruction / tool / recurring error.
  def insights(rows)
    out = []
    out.concat(knowledge_insights(rows))
    out.concat(instruction_insights(rows))
    out.concat(tool_insights(rows))
    out.concat(error_insights(rows))
    out.sort_by { |i| -i[:count] }
  end

  def knowledge_insights(rows)
    rows.select { |r| knowledge_gap?(r) && r[:agent].present? }
        .group_by { |r| r[:agent] }
        .map { |name, group| { type: 'faq', agent: name, count: group.size, examples: examples(group) } }
  end

  def instruction_insights(rows)
    rows.select { |r| low_confidence?(r) && r[:agent].present? }
        .group_by { |r| r[:agent] }
        .map { |name, group| { type: 'instruction', agent: name, count: group.size, examples: examples(group) } }
  end

  def tool_insights(rows)
    rows.select { |r| r[:tool_missing] }
        .group_by { |r| [r[:agent], r[:tool]] }
        .map { |(name, tool), group| { type: 'tool', agent: name, tool: tool, count: group.size, examples: examples(group) } }
  end

  def error_insights(rows)
    rows.select { |r| r[:error_type].present? }
        .group_by { |r| r[:error_type] }
        .select { |_type, group| group.size >= RECURRING_ERROR_MIN }
        .map { |error_type, group| { type: 'error', error_type: error_type, count: group.size, examples: examples(group) } }
  end

  # Amostra de perguntas (conversa + texto) por trás de cada lacuna, p/ o drill-down do front —
  # antes ele refiltrava a lista completa de runs; agora a paginação só traz 1 página.
  def examples(group)
    group.first(EXAMPLES_PER_INSIGHT).map do |r|
      { id: r[:id], conversation_id: r[:conversation_id], question: r[:question], message_id: r[:question_message_id] }
    end
  end

  def facets(scope)
    agent_ids = scope.where.not(ai_agent_id: nil).distinct.pluck(:ai_agent_id)
    {
      agents: ::Ai::Agent.where(id: agent_ids).pluck(:id, :name).map { |id, name| { id: id, name: name } },
      error_types: scope.where.not(error_type: nil).distinct.pluck(:error_type),
      statuses: scope.distinct.pluck(:status)
    }
  end

  # Pergunta do cliente que disparou cada run (do evento message.received), p/ o drill-down das
  # lacunas mostrar "quais perguntas". Uma query batch, casada por janela de tempo como routing.
  def questions_for(runs)
    conv_ids = runs.map(&:conversation_id).compact.uniq
    return {} if conv_ids.empty?

    events = ::Ai::Event.where(conversation_id: conv_ids, event_type: 'message.received')
                        .pluck(:conversation_id, :created_at, :payload)
    by_conversation = events.group_by(&:first)
    runs.each_with_object({}) do |run, acc|
      candidates = by_conversation[run.conversation_id]
      next if candidates.blank?

      window = (run.created_at - 5.seconds)..(run.updated_at + 2.seconds)
      match = candidates.find { |(_conv, created_at, _payload)| window.cover?(created_at) } || candidates.last
      next unless match

      # message_id só existe em eventos novos; runs antigas ficam sem âncora (abrem no topo).
      acc[run.id] = { text: match[2]['content'].to_s.first(200), message_id: match[2]['message_id'] }
    end
  end

  def agent_names(runs)
    ids = runs.map(&:ai_agent_id).compact.uniq
    ::Ai::Agent.where(id: ids).pluck(:id, :name).to_h
  end

  def agent_tools(runs)
    ids = runs.map(&:ai_agent_id).compact.uniq
    ::Ai::Tool.where(ai_agent_id: ids).pluck(:ai_agent_id, :name)
              .each_with_object(Hash.new { |h, k| h[k] = [] }) do |(agent_id, name), acc|
      acc[agent_id] << name.to_s.downcase
    end
  end
end
