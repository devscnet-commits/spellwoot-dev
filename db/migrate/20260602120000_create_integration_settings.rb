class CreateIntegrationSettings < ActiveRecord::Migration[7.1]
  def change
    create_table :integration_settings do |t|
      t.references :account, null: false, foreign_key: true, index: false
      t.string :provider, null: false
      t.text :config
      t.timestamps
    end
    add_index :integration_settings, [:account_id, :provider], unique: true
  end
end
