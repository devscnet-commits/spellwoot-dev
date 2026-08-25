# Temperatura do supervisor por perfil de operação (o "nível de atendimento"). Antes o Gateway não
# passava temperature nenhuma -> a IA rodava no default do provedor (~1.0, criativo demais p/
# atendimento). Agora o perfil carrega a temperatura (default 0.3, mais consistente) e o ModelRouter
# a aplica via chat.with_temperature. decimal(3,2) cobre a faixa 0-2 aceita pelos provedores.
class AddSupervisorTemperatureToAiOperationProfiles < ActiveRecord::Migration[7.1]
  def change
    add_column :ai_operation_profiles, :supervisor_temperature, :decimal,
               precision: 3, scale: 2, default: 0.3, null: false
  end
end
