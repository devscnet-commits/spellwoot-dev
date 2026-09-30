# Módulo do plano liberado para a conta? Regra única das travas de módulo novas (canais na criação da caixa,
# relatórios, copiloto, Conversões Meta): conta SEM plano atual nunca é barrada (contas internas/dev e contas
# antigas cujo bitmask não tem a flag); conta COM plano segue o bitmask, que é a projeção do plano
# (Plan#sync_features_to!). Mesma regra dos limites (FeatureGate.limit_action: sem plano => libera).
class Billing::PlanModules
  def self.allowed?(account, account_flag)
    return true if account.nil?

    # Plano lido na hora (sem ler nem gravar o cache por request do FeatureGate).
    return true if FeatureGate.current_plan(account, fresh: true).nil?

    account.feature_enabled?(account_flag)
  end
end
