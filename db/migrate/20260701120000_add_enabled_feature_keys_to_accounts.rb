# Passo 1 da migração de feature flags: bit-packed (feature_flags bigint, teto de 63)
# -> lista de chaves (enabled_feature_keys text[], sem limite, legível, pronta p/ o SaaS).
# Aditivo: a coluna nasce vazia e sem uso; o backfill e a troca do concern vêm nos próximos
# passos. feature_flags NÃO é tocado aqui (só é dropado no último passo, após soak em produção).
class AddEnabledFeatureKeysToAccounts < ActiveRecord::Migration[7.1]
  def change
    add_column :accounts, :enabled_feature_keys, :string, array: true, null: false, default: []
    # GIN: dá suporte eficiente aos scopes de feature (enabled_feature_keys @> ARRAY['x']).
    add_index :accounts, :enabled_feature_keys, using: :gin
  end
end
