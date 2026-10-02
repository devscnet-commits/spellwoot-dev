class CreatePipelineAutomations < ActiveRecord::Migration[7.1]
  def change
    create_automations
    create_runs
  end

  private

  def create_automations
    create_table :pipeline_automations do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.references :operational_flow, null: false, foreign_key: { on_delete: :cascade }
      t.references :resolution_state, null: false, foreign_key: { on_delete: :cascade }
      t.string :name, null: false
      t.boolean :active, null: false, default: true
      # automation (stage rules) | ai_followup (the stage's AI follow-up cadence, run in order)
      t.string :kind, null: false, default: 'automation'
      # stage_entered | time_in_stage | inactivity
      t.string :trigger_type, null: false, default: 'stage_entered'
      t.integer :delay_minutes, null: false, default: 0
      # Inactivity only: who sent the last message — contact | agent | any
      t.string :inactivity_sender, null: false, default: 'any'
      t.jsonb :conditions, null: false, default: []
      # all = every condition must match (E), any = at least one (OU)
      t.string :match_type, null: false, default: 'all'
      t.jsonb :actions, null: false, default: []
      t.integer :sort_order, null: false, default: 0

      t.timestamps
    end

    add_index :pipeline_automations, %i[active trigger_type]
  end

  # Idempotency ledger: one run per automation, conversation and anchor (the stage entry or the
  # last message the inactivity is measured from), so sweeps never fire the same thing twice.
  def create_runs
    create_table :pipeline_automation_runs do |t|
      t.references :pipeline_automation, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :conversation, null: false, foreign_key: { on_delete: :cascade }
      t.datetime :anchor_at, null: false
      t.string :status, null: false, default: 'running'
      t.string :error
      t.timestamps
    end

    add_index :pipeline_automation_runs, %i[pipeline_automation_id conversation_id anchor_at],
              unique: true, name: 'idx_pipeline_automation_runs_unique'
  end
end
