# Enforcement de limites de plano (billing Fase 2). Bloqueia a criação quando o plano atual da conta
# atingiu o limite da chave. Reusa o gate da Fase 1 (FeatureGate.within_limit?, que respeita
# max_value nil = ilimitado e ausência de limite = liberado) e a resposta 402 já usada pelos
# limites do Chatwoot (render_payment_required).
module PlanLimitEnforceable
  extend ActiveSupport::Concern

  private

  # `current_count` = quantos já existem. Passamos current_count + 1 (o total que resultaria) para
  # checar se cabe MAIS UM. Sem plano/limite => within_limit? true => não bloqueia.
  def enforce_plan_limit(key, current_count, message)
    return if FeatureGate.within_limit?(Current.account, key, current_count + 1)

    render_payment_required(message)
  end
end
