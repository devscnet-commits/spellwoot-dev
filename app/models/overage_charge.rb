# Cobrança de excedente de um ciclo (billing Fase 2). total_cents = média dos OverageSnapshot do
# período × overage_price_cents. Criada pela Ai::CreditsRenewalJob no fim do ciclo; status pending
# = aguardando cobrança manual (Stripe/Asaas é Fase 3).
# == Schema Information
#
# Table name: overage_charges
#
#  id               :bigint           not null, primary key
#  average_excess   :decimal(10, 2)
#  cycle_end        :datetime
#  cycle_start      :datetime
#  plan_limit_key   :string           not null
#  status           :integer          default("pending"), not null
#  total_cents      :integer
#  unit_price_cents :integer
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  account_id       :bigint           not null
#  subscription_id  :bigint           not null
#
# Indexes
#
#  index_overage_charges_on_account_id       (account_id)
#  index_overage_charges_on_subscription_id  (subscription_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (subscription_id => subscriptions.id)
#
class OverageCharge < ApplicationRecord
  belongs_to :account
  belongs_to :subscription

  enum status: { pending: 0, invoiced: 1 }

  validates :plan_limit_key, presence: true
  validates :total_cents, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
end
