class CreateAiVersions < ActiveRecord::Migration[7.1]
  def change
    create_table :ai_versions do |t|
      t.bigint :account_id, null: false
      t.string :versionable_type, null: false
      t.bigint :versionable_id, null: false
      t.integer :version_number, null: false, default: 1
      t.jsonb :snapshot, null: false, default: {}
      t.string :note
      t.timestamps
    end
    add_index :ai_versions, %i[versionable_type versionable_id]
  end
end
