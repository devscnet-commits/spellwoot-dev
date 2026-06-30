# Shadow intelligence panel — read-only analysis of AI Core runs for the continuous-improvement
# loop (evaluate -> find gap -> fix FAQ/instruction/tool -> measure again). Derives, per run, how
# the AI resolved (knowledge / instruction / tool / transfer / closed / unanswered / error) and
# rolls that up into KPIs, diagnostic blocks and actionable insights. Reuses existing data only.
class Api::V1::Accounts::AiShadowRunsController < Api::V1::Accounts::BaseController
  LOW_CONFIDENCE = 0.5
  RECURRING_ERROR_MIN = 2
  RUN_LIMIT = 300
  DEFAULT_PER_PAGE = 10
  MAX_PER_PAGE = 100
  EXAMPLES_PER_INSIGHT = 25

  def index
    base = ::Ai::Run.where(account_id: Current.account.id)
    base = apply_period(base)

    runs = filtered(base).order(created_at: :desc).limit(RUN_LIMIT).to_a
    runs = apply_decision_filters(runs)

    dept_names = department_names(runs)
    dept_tools = department_tools(runs)
    methods = routing_methods(runs)
    questions = questions_for(runs)

    rows = runs.map { |run| row(run, dept_names, dept_tools, methods, questions) }

    page, per_page = pagination_params
    total = rows.size
    paged = rows.slice((page - 1) * per_page, per_page) || []

    render json: {
      facets: facets(base),
      summary: summary(rows),
      insights: insights(rows),
      runs: paged,
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
  # O resumo/insights continuam calculados sobre toda a janela (RUN_LIMIT), não sobre a página.
  def pagination_params
    page = params[:page].to_i
    page = 1 if page < 1
    per_page = params[:per_page].to_i
    per_page = DEFAULT_PER_PAGE if per_page < 1
    per_page = MAX_PER_PAGE if per_page > MAX_PER_PAGE
    [page, per_page]
  end

  def period_start
    days = params[:days].to_i
    days.positive? ? days.days.ago : nil
  end

  # Filtro de data: intervalo customizado (from/to em YYYY-MM-DD) tem prioridade; senão usa ?days=N.
  def apply_period(scope)
    from = parse_date(params[:from])
    to = parse_date(params[:to])
    if from && to
      scope.where(created_at: from.beginning_of_day..to.end_of_day)
    elsif from
      scope.where('ai_runs.created_at >= ?', from.beginning_of_day)
    elsif to
      scope.where('ai_runs.created_at <= ?', to.end_of_day)
    elsif period_start
      scope.where('ai_runs.created_at >= ?', period_start)
    else
      scope
    end
  end

  def parse_date(value)
    return nil if value.blank?

    Date.parse(value.to_s)
  rescue ArgumentError, TypeError
    nil
  end

  def filtered(scope)
    scope = scope.where(ai_department_id: params[:department_id]) if params[:department_id].present?
    scope = scope.where(error_type: params[:error_type]) if params[:error_type].present?
    scope = scope.where(status: params[:status]) if params[:status].present?
    scope = scope.where(conversation_id: params[:conversation_id]) if params[:conversation_id].present?
    scope
  end

  # has_reply / has_tool / resolution live in the decision jsonb — filter in Ruby after load.
  def apply_decision_filters(runs)
    runs = runs.select { |r| reply_text(r).present? } if params[:has_reply] == 'true'
    runs = runs.reject { |r| reply_text(r).present? } if params[:has_reply] == 'false'
    runs = runs.select { |r| tool_name(r).present? } if params[:has_tool] == 'true'
    runs = runs.reject { |r| tool_name(r).present? } if params[:has_tool] == 'false'
    runs
  end

  def row(run, dept_names, dept_tools, methods, questions)
    tool = tool_name(run)
    missing = tool.present? && !dept_tools[run.ai_department_id].to_a.include?(tool.downcase)
    {
      id: run.id,
      conversation_id: run.conversation_id,
      question: questions[run.id],
      department_id: run.ai_department_id,
      department: dept_names[run.ai_department_id],
      routing_method: methods[run.id],
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

  def summary(rows)
    by_resolution = rows.group_by { |r| r[:resolution] }.transform_values(&:size)
    {
      evaluated: rows.size,
      unanswered: by_resolution['unanswered'].to_i,
      errors: rows.count { |r| r[:error_type].present? },
      low_confidence: rows.count { |r| low_confidence?(r) },
      tools_suggested: rows.count { |r| r[:tool].present? },
      tools_missing: rows.count { |r| r[:tool_missing] },
      knowledge_gaps: rows.count { |r| %w[unanswered instruction].include?(r[:resolution]) },
      by_resolution: by_resolution,
      by_department: by_department(rows),
      by_error: rows.select { |r| r[:error_type].present? }
                    .group_by { |r| r[:error_type] }.transform_values(&:size)
                    .map { |error_type, count| { error_type: error_type, count: count } }
                    .sort_by { |e| -e[:count] }
    }
  end

  def by_department(rows)
    rows.select { |r| r[:department].present? }.group_by { |r| r[:department] }.map do |name, group|
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
    rows.select { |r| %w[unanswered instruction].include?(r[:resolution]) && r[:department].present? }
        .group_by { |r| r[:department] }
        .map { |name, group| { type: 'faq', department: name, count: group.size, examples: examples(group) } }
  end

  def instruction_insights(rows)
    rows.select { |r| low_confidence?(r) && r[:department].present? }
        .group_by { |r| r[:department] }
        .map { |name, group| { type: 'instruction', department: name, count: group.size, examples: examples(group) } }
  end

  def tool_insights(rows)
    rows.select { |r| r[:tool_missing] }
        .group_by { |r| [r[:department], r[:tool]] }
        .map { |(name, tool), group| { type: 'tool', department: name, tool: tool, count: group.size, examples: examples(group) } }
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
      { id: r[:id], conversation_id: r[:conversation_id], question: r[:question] }
    end
  end

  def facets(scope)
    dept_ids = scope.where.not(ai_department_id: nil).distinct.pluck(:ai_department_id)
    {
      departments: ::Ai::Department.where(id: dept_ids).pluck(:id, :name).map { |id, name| { id: id, name: name } },
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
      acc[run.id] = match[2]['content'].to_s.first(200) if match
    end
  end

  def department_names(runs)
    ids = runs.map(&:ai_department_id).compact.uniq
    ::Ai::Department.where(id: ids).pluck(:id, :name).to_h
  end

  def department_tools(runs)
    ids = runs.map(&:ai_department_id).compact.uniq
    ::Ai::Tool.where(ai_department_id: ids).pluck(:ai_department_id, :name)
              .each_with_object(Hash.new { |h, k| h[k] = [] }) do |(dept_id, name), acc|
      acc[dept_id] << name.to_s.downcase
    end
  end

  # Maps run.id => routing method (single/inbox_mapping/classifier/default/fallback) from the
  # existing `department.resolved` event. One batched query; matched to each run by time window.
  def routing_methods(runs)
    conv_ids = runs.map(&:conversation_id).compact.uniq
    return {} if conv_ids.empty?

    events = ::Ai::Event.where(conversation_id: conv_ids, event_type: 'department.resolved')
                        .pluck(:conversation_id, :created_at, :payload)
    by_conversation = events.group_by(&:first)
    runs.each_with_object({}) do |run, acc|
      candidates = by_conversation[run.conversation_id]
      next if candidates.blank?

      window = run.created_at..(run.updated_at + 2.seconds)
      match = candidates.find { |(_conv, created_at, _payload)| window.cover?(created_at) }
      acc[run.id] = (match || candidates.last)[2]['method'] if match || candidates.last
    end
  end
end
