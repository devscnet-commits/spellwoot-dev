# Passo 4 (final) da migração de feature flags: dropa accounts.feature_flags (bigint bitmask), já
# substituído por accounts.enabled_feature_keys no Passo 3 (concern Featurable), após soak em prod.
# Nada no app lê/escreve mais essa coluna; Account.ignored_columns já a desacopla do schema em cache.
#
# IMPORTANTE: especifica :accounts explicitamente — NÃO confundir com channel_web_widgets.feature_flags
# (coluna homônima, integer, ainda em uso via FlagShihTzu). Esta migration NÃO a toca.
#
# Reversível: o down recria a coluna (vazia, default 0). Atenção — isso NÃO restaura o bitmask
# original; a fonte de verdade é enabled_feature_keys. Ver [[feature-flags-63-limit]].
class DropFeatureFlagsFromAccounts < ActiveRecord::Migration[7.1]
  def change
    remove_column :accounts, :feature_flags, :bigint, default: 0, null: false
  end
end
