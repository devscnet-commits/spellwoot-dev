# External connectors (Bitrix, webhooks, ERP, ...). A Tool with implementation_type=integration
# resolves to one of these. Additive; ai_* only. Column is `kind` (not `type`) to avoid Rails STI.
class CreateAiIntegrationLinks < ActiveRecord::Migration[7.1]
  def change
    create_table :ai_integration_links do |t|
      t.bigint :account_id, null: false
      t.string :name, null: false
      t.string :kind, null: false, default: 'webhook' # bitrix | webhook | erp | n8n | ...
      t.string :endpoint
      t.string :http_method, null: false, default: 'POST'
      t.jsonb  :auth, null: false, default: {}            # { type: bearer|header, token/header/value }
      t.jsonb  :headers, null: false, default: {}
      t.jsonb  :payload_template, null: false, default: {}
      t.integer :retry_count, null: false, default: 0
      t.integer :timeout_seconds, null: false, default: 10
      t.decimal :cost, precision: 12, scale: 6, null: false, default: 0
      t.string :status, null: false, default: 'active'
      t.timestamps
    end
    add_index :ai_integration_links, :account_id
  end
end
