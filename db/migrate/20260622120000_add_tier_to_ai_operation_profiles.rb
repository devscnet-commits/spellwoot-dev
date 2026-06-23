# Stores which service level a profile represents, so the UI can show the level's effect
# (Econômico/Equilibrado/Máxima Qualidade/Personalizado) instead of the internal engine.
class AddTierToAiOperationProfiles < ActiveRecord::Migration[7.1]
  def up
    add_column :ai_operation_profiles, :tier, :string, null: false, default: 'customizado'

    # Backfill the known default level names so existing rows show the right level.
    { 'Econômico' => 'economico', 'Balanceado' => 'balanceado', 'Premium' => 'premium' }.each do |name, tier|
      connection.execute(
        "UPDATE ai_operation_profiles SET tier = #{connection.quote(tier)} WHERE name = #{connection.quote(name)}"
      )
    end
  end

  def down
    remove_column :ai_operation_profiles, :tier
  end
end
