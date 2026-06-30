class CreateStickers < ActiveRecord::Migration[7.1]
  def change
    create_table :stickers do |t|
      t.bigint :account_id, null: false
      t.string :name
      t.timestamps
    end
    add_index :stickers, :account_id
  end
end
