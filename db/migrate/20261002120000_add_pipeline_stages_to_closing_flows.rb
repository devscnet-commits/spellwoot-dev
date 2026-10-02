class AddPipelineStagesToClosingFlows < ActiveRecord::Migration[7.1]
  # Closing flows become sales pipelines: neutral resolution states are the open stages of the
  # kanban (one of them is the default entry stage), won/lost stay as the closing columns.
  def change
    add_column :resolution_states, :is_default, :boolean, null: false, default: false
    add_column :resolution_states, :color, :string

    # Custom attribute summed as the deal value in the kanban columns and reports.
    add_column :operational_flows, :value_attribute_key, :string

    add_reference :conversations, :pipeline_stage, foreign_key: { to_table: :resolution_states, on_delete: :nullify }
    add_column :conversations, :pipeline_stage_entered_at, :datetime
    add_column :conversations, :temperature, :integer
    # Deadline (SLA) of the card in its current stage, set by a stage automation; cleared on stage change.
    add_column :conversations, :pipeline_sla_due_at, :datetime
  end
end
