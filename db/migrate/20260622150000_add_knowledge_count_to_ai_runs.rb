# Shadow intelligence — records how many knowledge chunks fed each run, so the analysis can tell
# "answered by knowledge" from "answered by instruction" without re-querying ai_events.
# Additive only; populated by the Gateway.
class AddKnowledgeCountToAiRuns < ActiveRecord::Migration[7.1]
  def change
    add_column :ai_runs, :knowledge_count, :integer, null: false, default: 0
  end
end
