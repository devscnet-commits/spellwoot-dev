class CreateAgentSchedules < ActiveRecord::Migration[7.0]
  def change
    create_table :agent_schedules do |t|
      t.references :user, null: false, foreign_key: true
      t.references :account, null: false, foreign_key: true
      t.integer :day_of_week, null: false
      t.boolean :closed_all_day, default: false, null: false
      t.boolean :open_all_day, default: false, null: false
      t.integer :open_hour
      t.integer :open_minutes
      t.integer :close_hour
      t.integer :close_minutes
      t.timestamps
    end
    add_index :agent_schedules, [:user_id, :day_of_week], unique: true
  end
end
