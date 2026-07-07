# Snapshot DIÁRIO do excedente dos limites em paid_overage (billing Fase 2). Roda de madrugada
# (config/schedule.yml, 04:30 UTC — depois do retention 03:30 e do credits_renewal 04:00).
#
# Para cada Subscription ativa, em cada PlanLimit :paid_overage do plano:
#   excess = max(uso_atual - max_value, 0) e faz upsert de 1 OverageSnapshot para hoje (idempotente:
#   re-rodar no mesmo dia atualiza, não duplica — índice único [account, chave, dia]).
#
# A cobrança em si (média × preço) é feita no fim do ciclo pela Ai::CreditsRenewalJob.
class Billing::OverageSnapshotJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform
    date = Time.current.to_date
    Subscription.active.includes(plan: :plan_limits).find_each do |subscription|
      snapshot(subscription, date)
    end
  end

  private

  def snapshot(subscription, date)
    account = subscription.account
    subscription.plan.plan_limits.select(&:paid_overage?).each do |limit|
      current = Billing::LimitUsage.current_count(account, limit.key)
      next if current.nil? || limit.max_value.nil?

      excess = [current - limit.max_value, 0].max
      upsert_snapshot(account, limit.key, date, excess)
    end
  end

  def upsert_snapshot(account, key, date, excess)
    snapshot = OverageSnapshot.find_or_initialize_by(
      account_id: account.id, plan_limit_key: key, snapshot_date: date
    )
    snapshot.update!(excess_count: excess)
  end
end
