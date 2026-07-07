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
# NÃO cobra nada nem integra billing externo (Stripe/Asaas) — isso é a Fase 3.
class Ai::CreditsRenewalJob < ApplicationJob
  queue_as :scheduled_jobs

  def perform
    Subscription.active.where(next_renewal_at: ..Time.current).find_each do |subscription|
      renew(subscription)
    end
  end

  private

  def renew(subscription)
    account = subscription.account
    balance = account.ai_credit_balance || account.build_ai_credit_balance
    balance.update!(plan_credits: subscription.plan.ai_credits_included)

    subscription.update!(next_renewal_at: advance_renewal(subscription.next_renewal_at))
  end

  # Avança em passos de 1 mês a partir do marco anterior até ultrapassar agora, preservando o dia.
  def advance_renewal(from)
    next_at = from
    next_at += 1.month while next_at <= Time.current
    next_at
  end
end
