class CreatePipelineAutomations < ActiveRecord::Migration[7.1]
  def change
    create_automations
    create_runs
    create_ai_followups
  end

  private

  def create_automations
    create_table :pipeline_automations do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.references :operational_flow, null: false, foreign_key: { on_delete: :cascade }
      t.references :resolution_state, null: false, foreign_key: { on_delete: :cascade }
      t.string :name, null: false
      t.boolean :active, null: false, default: true
      # Entries/silences that started before this never fire the rule (no burst on the backlog).
      t.datetime :activated_at
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

  # The AI follow-up cadence of a stage, same shape as the AI agent's own follow-up (behaviors per
  # schedule context, attempts, action when the customer does not answer).
  def create_ai_followups
    create_table :pipeline_ai_followups do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.references :operational_flow, null: false, foreign_key: { on_delete: :cascade }
      t.references :resolution_state, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.boolean :active, null: false, default: true
      # Silences that started before this never get the cadence (no burst on the backlog).
      t.datetime :activated_at
      # Minutes of silence after the last attempt before the no-response action runs.
      t.integer :inactivity_minutes, null: false, default: 30
      t.string :close_message
      t.jsonb :behaviors, null: false, default: []

      t.timestamps
    end
  end
end
