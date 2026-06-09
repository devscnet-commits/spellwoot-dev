class AddTeamIdToReportingEvents < ActiveRecord::Migration[7.0]
  disable_ddl_transaction!

  def up
    add_column :reporting_events, :team_id, :integer
    add_index :reporting_events, :team_id, algorithm: :concurrently
    add_index :reporting_events, %i[account_id team_id name created_at],
              name: 'idx_re_account_team_name_date', algorithm: :concurrently

    execute <<~SQL
      UPDATE reporting_events re
      SET team_id = c.team_id
      FROM conversations c
      WHERE re.conversation_id = c.id
        AND c.team_id IS NOT NULL
    SQL
  end

  def down
    remove_column :reporting_events, :team_id
  end
end
