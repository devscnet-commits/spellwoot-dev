# F1.0 / items D + E — dimension ai_runs for per-department/per-inbox metrics and give
# Shadow a structured failure reason. Additive only; all columns nullable. Populated by the
# Gateway in F1.1 — nothing reads or writes them yet.
class AddDimensionsAndErrorTypeToAiRuns < ActiveRecord::Migration[7.1]
  def change
    # D — metric dimensions
    add_column :ai_runs, :ai_department_id, :bigint
    add_column :ai_runs, :inbox_id, :bigint
    add_column :ai_runs, :routing_band, :string
    add_column :ai_runs, :worker, :string

    # E — structured error taxonomy for Shadow
    add_column :ai_runs, :error_type, :string

    add_index :ai_runs, :ai_department_id
    add_index :ai_runs, :inbox_id
  end
end
