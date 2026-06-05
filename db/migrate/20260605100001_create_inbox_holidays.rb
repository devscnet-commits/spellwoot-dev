class CreateInboxHolidays < ActiveRecord::Migration[7.0]
  def change
    create_table :inbox_holidays do |t|
      t.references :inbox,    null: false, foreign_key: true
      t.bigint      :account_id
      t.string      :name,        null: false
      t.integer     :holiday_month, null: false
      t.integer     :holiday_day,   null: false
      t.integer     :holiday_year
      t.boolean     :recurring,    null: false, default: true
      t.timestamps
    end

    add_index :inbox_holidays, :account_id
  end
end
