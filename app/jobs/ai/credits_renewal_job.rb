# Renova os créditos de plano (AiCreditBalance#plan_credits) das assinaturas ATIVAS cujo ciclo
# mensal venceu (next_renewal_at <= agora). Roda diariamente (config/schedule.yml, 04:00 UTC).
#
# Regras (billing Fase 2):
#  - plan_credits NÃO acumula: reseta para o valor do plano (Plan#ai_credits_included). O saldo não
#    usado do ciclo anterior é perdido.
#  - extra_credits (créditos comprados avulsos) NUNCA são tocados na renovação.
#  - O dia de aniversário é preservado avançando next_renewal_at em passos de 1 mês até cair no
#    futuro — sem drift e sem renovar 2x se o cron atrasar (uma renovação cobre o buraco).
#
# Ao fechar o ciclo, também registra o excedente pago (OverageCharge) a partir da MÉDIA dos snapshots
# diários do ciclo. NÃO integra billing externo (Stripe/Asaas) nem envia fatura — isso é a Fase 3;
# a OverageCharge fica `pending` para cobrança manual.
class Ai::CreditsRenewalJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform
    Subscription.active.where(next_renewal_at: ..Time.current)
                .includes(plan: :plan_limits).find_each do |subscription|
      renew(subscription)
    end
  end

  private

  def renew(subscription)
    # Cobra o excedente do ciclo que está FECHANDO antes de avançar o marco (os limites do período
    # são [next_renewal_at anterior, next_renewal_at]).
    charge_overage(subscription)

    account = subscription.account
    balance = account.ai_credit_balance || account.build_ai_credit_balance
    balance.update!(plan_credits: subscription.plan.ai_credits_included)

    subscription.update!(next_renewal_at: advance_renewal(subscription.next_renewal_at))
  end

  # Para cada limite em paid_overage: média dos OverageSnapshot do ciclo × preço unitário -> OverageCharge
  # pending. Sem excedente médio (== 0) => nada a cobrar. cycle_end = marco atual; cycle_start = -1 mês.
  def charge_overage(subscription)
    cycle_end = subscription.next_renewal_at
    return if cycle_end.nil?

    cycle_start = cycle_end - 1.month
    account = subscription.account

    subscription.plan.plan_limits.select(&:paid_overage?).each do |limit|
      average = average_excess(account, limit.key, cycle_start, cycle_end)
      next if average <= 0

      unit_price = limit.overage_price_cents.to_i
      OverageCharge.create!(
        account_id: account.id,
        subscription_id: subscription.id,
        plan_limit_key: limit.key,
        cycle_start: cycle_start,
        cycle_end: cycle_end,
        average_excess: average,
        unit_price_cents: unit_price,
        total_cents: (average * unit_price).round,
        status: :pending
      )
    end
  end

  # Média dos excess_count dos snapshots do período [cycle_start, cycle_end] (por data). 0 se não houver.
  def average_excess(account, key, cycle_start, cycle_end)
    snapshots = OverageSnapshot.where(account_id: account.id, plan_limit_key: key,
                                      snapshot_date: cycle_start.to_date..cycle_end.to_date)
    count = snapshots.count
    return 0 if count.zero?

    (snapshots.sum(:excess_count).to_f / count).round(2)
  end

  # Avança em passos de 1 mês a partir do marco anterior até ultrapassar agora, preservando o dia.
  def advance_renewal(from)
    next_at = from
    next_at += 1.month while next_at <= Time.current
    next_at
  end
end
