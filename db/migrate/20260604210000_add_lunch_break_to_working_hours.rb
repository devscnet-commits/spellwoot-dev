class AddLunchBreakToWorkingHours < ActiveRecord::Migration[7.0]
  def change
    add_column :working_hours, :has_lunch_break,      :boolean, default: false, null: false
    add_column :working_hours, :lunch_start_hour,     :integer
    add_column :working_hours, :lunch_start_minutes,  :integer
    add_column :working_hours, :lunch_end_hour,       :integer
    add_column :working_hours, :lunch_end_minutes,    :integer
  end
end
