# Read-only AI metrics aggregation for the account (from ai_runs). Observability only.
# Costs are recomputed from the real token counts using the current price table
# (Ai::ModelRouter.price_for), so the screen always reflects today's prices and the
# input/output split adds up. Breakdowns by model / agent / error type, with an optional
# period window (?days=N) and an optional agent filter (?agent_id=N).
class Api::V1::Accounts::AiCostsController < Api::V1::Accounts::BaseController
  def index
    scope = ::Ai::Run.where(account_id: Current.account.id)
    scope = apply_period(scope)
    scope = scope.where(ai_agent_id: params[:agent_id]) if params[:agent_id].present?

    models = by_model(scope)
    cost_in = round6(models.sum { |m| m[:cost_in] })
    cost_out = round6(models.sum { |m| m[:cost_out] })

    render json: {
      total_cost: round6(cost_in + cost_out),
      total_cost_in: cost_in,
      total_cost_out: cost_out,
      total_tokens_in: scope.sum(:tokens_in),
      total_tokens_out: scope.sum(:tokens_out),
      total_runs: scope.count,
      total_errors: scope.where.not(error_type: nil).count,
      by_model: models,
      by_agent: by_agent(scope),
      by_error: by_error(scope)
    }
  end

  private

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

  def round6(value)
    value.to_f.round(6)
  end

  # input/output cost in USD for a token pair, using the current price table.
  def cost_split(tokens_in, tokens_out, model)
    input_price, output_price = ::Ai::ModelRouter.price_for(model)
    [round6(tokens_in.to_i / 1000.0 * input_price), round6(tokens_out.to_i / 1000.0 * output_price)]
  end

  def by_model(scope)
    scope.group(:provider, :model)
         .select('provider, model, COUNT(*) AS runs, SUM(tokens_in) AS tokens_in, ' \
                 'SUM(tokens_out) AS tokens_out, AVG(latency_ms) AS avg_latency')
         .map do |row|
      cost_in, cost_out = cost_split(row.tokens_in, row.tokens_out, row.model)
      { provider: row.provider, model: row.model, runs: row.runs,
        tokens_in: row.tokens_in.to_i, tokens_out: row.tokens_out.to_i,
        cost_in: cost_in, cost_out: cost_out, cost: round6(cost_in + cost_out),
        avg_latency: row.avg_latency&.round }
    end
  end

  # Recomputed cost per dimension: group by the key AND the model (price depends on model),
  # then fold the per-model token sums back into a single cost per key.
  def grouped_cost(scope, key)
    rows = scope.where.not(key => nil).group(key, :model)
                .select("#{key} AS gid, model, COUNT(*) AS runs, " \
                        'SUM(tokens_in) AS tokens_in, SUM(tokens_out) AS tokens_out')
    agg = Hash.new { |hash, gid| hash[gid] = { runs: 0, cost: 0.0 } }
    rows.each do |row|
      cost_in, cost_out = cost_split(row.tokens_in, row.tokens_out, row.model)
      bucket = agg[row.gid]
      bucket[:runs] += row.runs
      bucket[:cost] = round6(bucket[:cost] + cost_in + cost_out)
    end
    agg
  end

  def by_agent(scope)
    agg = grouped_cost(scope, :ai_agent_id)
    names = agent_names(agg.keys)
    agg.map { |id, row| { name: names[id] || "##{id}", runs: row[:runs], cost: row[:cost] } }
  end

  def by_error(scope)
    scope.where.not(error_type: nil).group(:error_type).count
         .map { |error_type, count| { error_type: error_type, count: count } }
  end

  def agent_names(ids)
    ::Ai::Agent.where(id: ids).pluck(:id, :assistant_name, :name).to_h do |id, assistant_name, name|
      [id, assistant_name.presence || name]
    end
  end
end
