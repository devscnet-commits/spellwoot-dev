# Cobrança de excedente de um ciclo (billing Fase 2). total_cents = média dos OverageSnapshot do
# período × overage_price_cents. Criada pela Ai::CreditsRenewalJob no fim do ciclo; status pending
# = aguardando cobrança manual (Stripe/Asaas é Fase 3).
class OverageCharge < ApplicationRecord
  belongs_to :account
  belongs_to :subscription

  enum status: { pending: 0, invoiced: 1 }

  validates :plan_limit_key, presence: true
  validates :total_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
end
