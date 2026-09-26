require 'administrate/field/base'

# Campo *_cents mostrado e digitado em reais. A conversão de volta para centavos acontece em
# SuperAdmin::PlansController#resource_params (MoneyCents.parse).
class MoneyCentsField < Administrate::Field::Base
  def to_s
    reais = MoneyCents.format(data)
    reais ? "R$ #{reais}" : '—'
  end

  def reais
    MoneyCents.format(data)
  end
end
