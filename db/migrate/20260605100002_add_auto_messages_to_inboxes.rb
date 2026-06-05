class AddAutoMessagesToInboxes < ActiveRecord::Migration[7.0]
  def change
    add_column :inboxes, :interval_message, :string
    add_column :inboxes, :holiday_message,  :string
  end
end
