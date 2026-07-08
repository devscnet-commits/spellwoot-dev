# Posição abstrata de temperatura (0-100, "rígido"->"criativo"). O usuário passa a escolher a posição
# e o Ai::TemperatureMapper traduz para a temperatura real de cada provider. supervisor_temperature
# (cru, 0-2) vira LEGADO — mantido por ora, sem uso ativo no fluxo (dropar em limpeza futura).
#
# Backfill: converte o supervisor_temperature legado de cada perfil para a posição, usando as âncoras
# do provider daquele perfil (inverse interpolation). default 20 (~0.3 na OpenAI, faixa consistente).
class AddTemperaturePositionToAiOperationProfiles < ActiveRecord::Migration[7.1]
  def up
    add_column :ai_operation_profiles, :temperature_position, :integer, null: false, default: 20

    Ai::OperationProfile.reset_column_information
    Ai::OperationProfile.find_each do |profile|
      position = Ai::TemperatureMapper.position_for(profile.supervisor_provider, profile.supervisor_temperature)
      profile.update_columns(temperature_position: position) # rubocop:disable Rails/SkipsModelValidations
    end
  end

  def down
    remove_column :ai_operation_profiles, :temperature_position
  end
end
