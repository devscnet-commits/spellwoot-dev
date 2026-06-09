class CreateTeamInboxes < ActiveRecord::Migration[7.1]
  def change
    create_table :team_inboxes do |t|
      t.references :team,  null: false, foreign_key: true
      t.references :inbox, null: false, foreign_key: true
      t.timestamps
    end

    add_index :team_inboxes, [:team_id, :inbox_id], unique: true
  end
end
