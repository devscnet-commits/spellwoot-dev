require 'administrate/field/base'

# Grade de limites numéricos do plano (Plan#limit_grid). Ver PlanFeaturesField para o padrão.
class PlanLimitsField < Administrate::Field::Base
  def to_s
    data
  end
end
