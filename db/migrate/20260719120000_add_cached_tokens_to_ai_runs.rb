# Prompt caching (medição): tokens de ENTRADA servidos do cache do provider (subconjunto de tokens_in).
# Nullable de propósito — runs antigos e providers que não reportam cache ficam NULL (distinto de 0, que
# significa "reportou e não houve cache"). NÃO altera estimate_cost por enquanto (só medição).
class AddCachedTokensToAiRuns < ActiveRecord::Migration[7.1]
  def change
    add_column :ai_runs, :cached_tokens, :integer
  end
end
