# Read-only AI cost aggregation for the account (from ai_runs). Observability only.
class Api::V1::Accounts::AiCostsController < Api::V1::Accounts::BaseController
  def index
    scope = ::Ai::Run.where(account_id: Current.account.id)

    by_model = scope.group(:provider, :model)
                    .select('provider, model, COUNT(*) AS runs, SUM(cost) AS cost, AVG(latency_ms) AS avg_latency')
                    .map do |row|
      {
        provider: row.provider,
        model: row.model,
        runs: row.runs,
        cost: row.cost,
        avg_latency: row.avg_latency&.round
      }
    end

    render json: {
      total_cost: scope.sum(:cost),
      total_runs: scope.count,
      by_model: by_model
    }
  end
end
