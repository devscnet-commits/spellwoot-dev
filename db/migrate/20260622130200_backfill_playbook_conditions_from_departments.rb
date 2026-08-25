# F1.0 / item B — move transfer/close conditions toward the playbook as the single source of
# truth. Copies department.transfer_rules.when / close_rules.when into the playbook arrays only
# when the playbook does not already define them (never overwrites). The department jsonb is
# left untouched; the runtime cutover to read playbook-only happens with the Gateway (F1.1),
# and the duplicate columns are dropped later (F1.5).
class BackfillPlaybookConditionsFromDepartments < ActiveRecord::Migration[7.1]
  def up
    execute <<~SQL.squish
      UPDATE ai_playbooks p
      SET transfer_when = d.transfer_rules->'when'
      FROM ai_departments d
      WHERE p.ai_department_id = d.id
        AND (p.transfer_when IS NULL OR p.transfer_when = '[]'::jsonb)
        AND jsonb_typeof(d.transfer_rules->'when') = 'array'
        AND jsonb_array_length(d.transfer_rules->'when') > 0
    SQL

    execute <<~SQL.squish
      UPDATE ai_playbooks p
      SET close_when = d.close_rules->'when'
      FROM ai_departments d
      WHERE p.ai_department_id = d.id
        AND (p.close_when IS NULL OR p.close_when = '[]'::jsonb)
        AND jsonb_typeof(d.close_rules->'when') = 'array'
        AND jsonb_array_length(d.close_rules->'when') > 0
    SQL
  end

  def down
    # No-op: additive consolidation; original department rules are preserved.
  end
end
