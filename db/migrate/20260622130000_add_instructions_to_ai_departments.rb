# F1.0 / item C — canonical column for the department long-form instructions.
# Additive: the UI wrote the value into behavior->>'instructions' while the column did not
# exist; this backfills the column from there. behavior.instructions is left in place as a
# read fallback and is only dropped later (F1.5), after the cutover.
class AddInstructionsToAiDepartments < ActiveRecord::Migration[7.1]
  def up
    add_column :ai_departments, :instructions, :text

    execute <<~SQL.squish
      UPDATE ai_departments
      SET instructions = behavior->>'instructions'
      WHERE instructions IS NULL
        AND jsonb_exists(behavior, 'instructions')
        AND COALESCE(behavior->>'instructions', '') <> ''
    SQL
  end

  def down
    remove_column :ai_departments, :instructions
  end
end
