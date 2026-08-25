# == Schema Information
#
# Table name: ai_credit_balances
#
#  id                      :bigint           not null, primary key
#  extra_credits           :integer          default(0), not null
#  low_balance_notified_at :datetime
#  plan_credits            :integer          default(0), not null
#  created_at              :datetime         not null
#  updated_at              :datetime         not null
#  account_id              :bigint           not null
#
# Indexes
#
#  index_ai_credit_balances_on_account_id  (account_id) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#
# Saldo CONSUMÍVEL de créditos de IA (não é limite). plan_credits renova no ciclo (valor do plano);
# extra_credits são comprados avulsos e não expiram.
class AiCreditBalance < ApplicationRecord
  belongs_to :account

  InsufficientCredits = Class.new(StandardError)

  def total
    plan_credits + extra_credits
  end

  # Desconta `amount` primeiro de plan_credits, depois de extra_credits. Atômico (row lock) para
  # evitar corrida sob concorrência. Retorna true; levanta InsufficientCredits se o total não cobrir.
  def consume!(amount)
    amount = amount.to_i
    raise ArgumentError, 'amount deve ser positivo' if amount <= 0

    with_lock do
      raise InsufficientCredits, "saldo insuficiente (tem #{total}, precisa #{amount})" if amount > total

      from_plan = [plan_credits, amount].min
      update!(plan_credits: plan_credits - from_plan,
              extra_credits: extra_credits - (amount - from_plan))
    end
    true
  end

  # Adiciona créditos avulsos (permanentes). Usado ao aprovar uma AiCreditRequest. Atômico (row lock).
  def credit_extra!(amount)
    amount = amount.to_i
    raise ArgumentError, 'amount deve ser positivo' if amount <= 0

    with_lock { update!(extra_credits: extra_credits + amount) }
    true
  end
end
