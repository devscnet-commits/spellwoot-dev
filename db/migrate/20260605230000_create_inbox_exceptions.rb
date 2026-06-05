class CreateInboxExceptions < ActiveRecord::Migration[7.1]
  def change
    create_table :inbox_exceptions do |t|
      t.references :inbox, null: false, foreign_key: true
      t.bigint  :account_id
      t.string  :name
      t.date    :exception_date, null: false
      t.boolean :closed, null: false, default: false
      t.jsonb   :periods, null: false, default: []
      t.timestamps
    end

    add_index :inbox_exceptions, :account_id
  end
end
