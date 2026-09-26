# Enforcement de limites de plano (billing Fase 2). Decide, pelo overflow_behavior do PlanLimit, se a
# criação é liberada, bloqueada (402) ou permitida como excedente pago. Reusa FeatureGate (que respeita
# max_value nil = ilimitado e ausência de limite = liberado) e a resposta 402 já usada pelos limites
# do Chatwoot (render_payment_required).
module PlanLimitEnforceable
  extend ActiveSupport::Concern

  private

  # Mesmo que enforce_plan_limit, contando o uso atual pela fonte única (Billing::LimitUsage).
  def enforce_plan_usage_limit(key, message, adding: 1)
    enforce_plan_limit(key, Billing::LimitUsage.current_count(Current.account, key), message, adding: adding)
  end

  # `current_count` = quantos já existem; `adding` = quantos a ação cria (1, ou N num convite em
  # massa). Checa o total que resultaria. Sem plano/limite => :allow => não bloqueia.
  def enforce_plan_limit(key, current_count, message, adding: 1)
    case FeatureGate.limit_action(Current.account, key, current_count + adding)
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
