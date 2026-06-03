class CreateProviderInstances < ActiveRecord::Migration[7.1]
  def change
    create_table :provider_instances do |t|
      t.references :account, null: false, foreign_key: true
      t.string :provider, null: false
      t.string :instance_id
      t.string :instance_name, null: false
      t.string :phone_number
      t.string :status, default: 'unknown'
      t.jsonb :raw_data, default: {}
      t.timestamps
    end

    add_index :provider_instances, %i[account_id provider]
    add_index :provider_instances, %i[account_id provider instance_name],
              unique: true, name: 'idx_provider_instances_unique'
  end
end
