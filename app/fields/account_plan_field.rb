require 'administrate/field/base'

# Plano da conta na tela do Super Admin. O vínculo conta→plano é uma Subscription: o campo lê
# `account.subscriptions` e mostra o plano da assinatura vigente (mesma regra de FeatureGate). O
# select grava por fora do namespace `account[...]` (campo `account_plan_id`) e quem troca a
# assinatura é SuperAdmin::AccountsController#update, via Plan::ChangeSubscriptionService#switch!.
class AccountPlanField < Administrate::Field::Base
  def to_s
    plan&.name || 'Sem plano'
  end

  def subscription
    @subscription ||= data.current.first
  end

  def plan
    subscription&.plan
  end

  def plan_options
    Plan.active.order(:name).map { |candidate| ["#{candidate.name} (#{candidate.slug})", candidate.id] }
  end
end
