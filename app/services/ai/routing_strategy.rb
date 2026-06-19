# Confidence-based routing over the RAG vector score (cosine similarity of the best candidate):
#   score >= high_threshold  -> serve from cache/knowledge, no LLM (instant, free)
#   low <= score < high      -> cheap model judges (serve or escalate)
#   score < low_threshold     -> premium model generates a fresh answer
# Pure decision; it picks the band/worker/model so the UI can explain WHY a model was used.
class Ai::RoutingStrategy
  DEFAULTS = { 'high_threshold' => 0.95, 'low_threshold' => 0.85 }.freeze

  def self.decide(score:, profile:)
    config = (profile&.routing_strategy || {}).reverse_merge(DEFAULTS)
    high = config['high_threshold'].to_f
    low  = config['low_threshold'].to_f

    if score && score >= high
      band('high', 'cache', 'cache', nil, nil)
    elsif score && score >= low
      band('mid', 'cheap', 'judge',
           config['cheap_provider'].presence || profile&.supervisor_provider,
           config['cheap_model'].presence || profile&.supervisor_model)
    else
      band('low', 'premium', 'generator',
           config['premium_provider'].presence || profile&.supervisor_provider,
           config['premium_model'].presence || profile&.supervisor_model)
    end
  end

  def self.band(name, action, worker, provider, model)
    { 'band' => name, 'action' => action, 'worker' => worker, 'provider' => provider, 'model' => model }
  end
end
