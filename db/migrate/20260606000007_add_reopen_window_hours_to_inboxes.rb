class AddReopenWindowHoursToInboxes < ActiveRecord::Migration[7.0]
  def change
    add_column :inboxes, :reopen_window_hours, :integer, default: 0, null: false
  end
end
