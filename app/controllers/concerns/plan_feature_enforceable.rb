# Enforcement de feature de plano via o bitmask da conta (Featurable) — mesmo mecanismo que já
# gateia audit_logs/webhooks server-side (Current.account.feature_enabled?). Deliberadamente NÃO usa
# FeatureGate.enabled? (nega por padrão sem subscription): sem Plan atribuído, a conta segue o
# default de config/features.yml, então isto não quebra contas que ainda não têm Subscription.
module PlanFeatureEnforceable
  extend ActiveSupport::Concern

  private

  def enforce_plan_feature(key, message)
    return if Current.account.feature_enabled?(key)

    render json: { error: message }, status: :forbidden
  end
end
