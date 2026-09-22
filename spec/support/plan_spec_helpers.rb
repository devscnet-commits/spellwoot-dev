# Liberar uma feature de plano numa conta deixou de ser `account.enable_features!(...)`: a regra de
# negócio lê o PLANO (FeatureGate), não o bitmask da conta — que é só uma projeção, reescrita pelo
# Plan#sync_features_to! no after_save da Subscription. Um bitmask setado à mão passa no teste e
# desaparece em produção na virada do ciclo; foi assim que a conta #7 ficou sem chave própria.
module PlanSpecHelpers
  # Dá à conta uma assinatura ativa de um plano com as features pedidas ligadas.
  # Devolve o plano, para quando o teste precisar mexer em limites ou créditos.
  def subscribe_account_to_plan(account, features: [], ai_credits: 0, limits: {})
    plan = Plan.create!(name: "Plano #{SecureRandom.hex(4)}", slug: "plano-#{SecureRandom.hex(4)}",
                        ai_credits_included: ai_credits)
    features.each { |key| plan.plan_features.create!(key: key.to_s, enabled: true) }
    limits.each { |key, max| plan.plan_limits.create!(key: key.to_s, max_value: max) }
    Subscription.create!(account: account, plan: plan, status: :active, started_at: Time.current)
    plan
  end

  # Atalho do caso mais comum: a conta pode usar chave própria de IA.
  def enable_byok!(account, ai_credits: 0)
    subscribe_account_to_plan(account, features: ['custom_llm_api_key'], ai_credits: ai_credits)
  end
end
