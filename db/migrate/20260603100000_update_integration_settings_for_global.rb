class UpdateIntegrationSettingsForGlobal < ActiveRecord::Migration[7.1]
  def change
    # Allow null account_id for global (system-level) settings
    change_column_null :integration_settings, :account_id, true

    # Drop old unique index (doesn't handle nulls correctly for global scope)
    remove_index :integration_settings, [:account_id, :provider]

    # Unique index for account-scoped settings (account_id NOT NULL)
    execute <<-SQL
      CREATE UNIQUE INDEX index_integration_settings_on_account_id_and_provider
      ON integration_settings (account_id, provider)
      WHERE account_id IS NOT NULL;
    SQL

    # Unique index for global settings (account_id IS NULL)
    execute <<-SQL
      CREATE UNIQUE INDEX index_integration_settings_global_provider
      ON integration_settings (provider)
      WHERE account_id IS NULL;
    SQL

    add_column :integration_settings, :enabled, :boolean, default: true, null: false
  end
end
