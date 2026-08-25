# Enforcement de limites de plano (billing Fase 2). Decide, pelo overflow_behavior do PlanLimit, se a
# criação é liberada, bloqueada (402) ou permitida como excedente pago. Reusa FeatureGate (que respeita
# max_value nil = ilimitado e ausência de limite = liberado) e a resposta 402 já usada pelos limites
# do Chatwoot (render_payment_required).
module PlanLimitEnforceable
  extend ActiveSupport::Concern

  private

  # `current_count` = quantos já existem. Passamos current_count + 1 (o total que resultaria) para
  # checar se cabe MAIS UM. Sem plano/limite => :allow => não bloqueia.
  def enforce_plan_limit(key, current_count, message)
    case FeatureGate.limit_action(Current.account, key, current_count + 1)
    when :block
      render_payment_required(message)
    # :allow e :allow_with_overage seguem sem bloquear a criação.
    #
    # overage pago ainda não tem registro de cobrança (aguardando Fase 3 — integração Stripe/Asaas).
    # Quando a cobrança for implementada, será necessário criar um mecanismo de contagem de excedente
    # por período. Por ora, :allow_with_overage apenas libera a criação (decisão consciente e temporária).
    end
  end
end
