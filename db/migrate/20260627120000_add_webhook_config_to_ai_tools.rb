# Ferramenta do tipo "webhook": guarda a config da requisição (url, método, cabeçalhos).
# O input da IA vira o corpo/parâmetros da chamada (ver Ai::WebhookRunner).
class AddWebhookConfigToAiTools < ActiveRecord::Migration[7.1]
  def change
    add_column :ai_tools, :webhook_config, :jsonb, null: false, default: {}
  end
end
