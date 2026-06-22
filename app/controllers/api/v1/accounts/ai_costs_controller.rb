# Read-only AI metrics aggregation for the account (from ai_runs). Observability only.
# Breakdowns by model / agent / department / error type, with an optional period window (?days=N).
class Api::V1::Accounts::AiCostsController < Api::V1::Accounts::BaseController
  def index
    scope = ::Ai::Run.where(account_id: Current.account.id)
    scope = scope.where('ai_runs.created_at >= ?', period_start) if period_start

    render json: {
      total_cost: scope.sum(:cost),
      total_runs: scope.count,
      total_errors: scope.where.not(error_type: nil).count,
      by_model: by_model(scope),
      by_agent: by_agent(scope),
      by_department: by_department(scope),
      by_error: by_error(scope)
    }
  end

  private

  def period_start
    days = params[:days].to_i
    days.positive? ? days.days.ago : nil
  end

  def by_model(scope)
    scope.group(:provider, :model)
         .select('provider, model, COUNT(*) AS runs, SUM(cost) AS cost, AVG(latency_ms) AS avg_latency')
         .map do |row|
      { provider: row.provider, model: row.model, runs: row.runs, cost: row.cost,
        avg_latency: row.avg_latency&.round }
    end
  end

  def by_agent(scope)
    rows = scope.where.not(ai_agent_id: nil).group(:ai_agent_id)
                .select('ai_agent_id, COUNT(*) AS runs, SUM(cost) AS cost')
    names = agent_names(rows.map(&:ai_agent_id))
    rows.map do |row|
      { name: names[row.ai_agent_id] || "##{row.ai_agent_id}", runs: row.runs, cost: row.cost }
    end
  end

  def by_department(scope)
    rows = scope.where.not(ai_department_id: nil).group(:ai_department_id)
                .select('ai_department_id, COUNT(*) AS runs, SUM(cost) AS cost')
    names = ::Ai::Department.where(id: rows.map(&:ai_department_id)).pluck(:id, :name).to_h
    rows.map do |row|
      { name: names[row.ai_department_id] || "##{row.ai_department_id}", runs: row.runs, cost: row.cost }
    end
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
