class CreateWorkingPeriods < ActiveRecord::Migration[7.0]
  def change
    create_table :working_periods do |t|
      t.references :inbox,   null: false, foreign_key: true
      t.bigint      :account_id
      t.integer     :day_of_week, null: false
      t.integer     :start_hour,  null: false
      t.integer     :start_minutes, null: false, default: 0
      t.integer     :end_hour,    null: false
      t.integer     :end_minutes, null: false, default: 0
      t.integer     :position,    null: false, default: 0
      t.timestamps
    end

    add_index :working_periods, :account_id
    add_index :working_periods, [:inbox_id, :day_of_week]
  end
end
