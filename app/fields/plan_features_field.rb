require 'administrate/field/base'

# Grade de features do plano (Plan#feature_grid) numa única célula do Administrate. Mesmo padrão do
# AccountFeaturesField: o dado é um Hash montado pelo model, e as partials em
# app/views/fields/plan_features_field/ desenham. Campos *_tag com nome próprio (fora do namespace
# `plan[...]`) — quem grava é SuperAdmin::PlansController, não o update do Administrate.
class PlanFeaturesField < Administrate::Field::Base
  def to_s
    data
  end
end
