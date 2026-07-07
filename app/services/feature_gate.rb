# Camada de consulta de plano (Fase 1: SÓ leitura — não faz enforcement/UI/billing). Responde, a
# partir da subscription ATUAL da conta, se uma feature está ligada e qual é o limite numérico.
#
# Memoiza o plano por request (RequestStore) para não repetir a query quando a mesma view chama o
# gate várias vezes. Como é por request, reflete mudanças de plano na requisição seguinte.
class FeatureGate
  class << self
    # Feature liga/desliga (PlanFeature). Sem plano/subscription atual => false (nega por padrão).
    def enabled?(account, feature_key)
      current_plan(account)&.feature_enabled?(feature_key) || false
    end

    # Retorna o PlanLimit (max_value + overflow_behavior) do plano atual, ou nil se não houver.
    def limit_for(account, limit_key)
      current_plan(account)&.limit_for(limit_key)
    end

    # true se `current_count` está DENTRO do limite (<= max_value). max_value nil (ilimitado) ou
    # limite ausente => sempre true. Para checar se cabe MAIS UM antes de criar, passe o total que
    # resultaria (ex.: current_count + 1).
    def within_limit?(account, limit_key, current_count)
      limit = limit_for(account, limit_key)
      return true if limit.nil? || limit.max_value.nil?

      current_count.to_i <= limit.max_value
    end

    # Plano da subscription atual da conta, memoizado por request.
    def current_plan(account)
      return nil if account.nil?

      cache = (RequestStore.store[:feature_gate_plans] ||= {})
      return cache[account.id] if cache.key?(account.id)

      cache[account.id] = account.subscriptions.current
                                 .includes(plan: %i[plan_features plan_limits]).first&.plan
    end
  end
end
