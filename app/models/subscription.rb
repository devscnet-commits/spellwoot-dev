# == Schema Information
#
# Table name: subscriptions
#
#  id              :bigint           not null, primary key
#  ends_at         :datetime
#  next_renewal_at :datetime
#  started_at      :datetime
#  status          :integer          default("active"), not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  account_id      :bigint           not null
#  plan_id         :bigint           not null
#
# Indexes
#
#  index_subscriptions_on_account_id             (account_id)
#  index_subscriptions_on_account_id_and_status  (account_id,status)
#  index_subscriptions_on_plan_id                (plan_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (plan_id => plans.id)
#
class Subscription < ApplicationRecord
  belongs_to :account
  belongs_to :plan

  enum status: { active: 0, trialing: 1, canceled: 2, past_due: 3 }

  # A "atual" da conta: a mais recente que ainda vale (não cancelada). Mantemos histórico via has_many.
  scope :current, -> { where.not(status: :canceled).order(started_at: :desc, id: :desc) }

  before_create :set_initial_renewal_date
  after_create :initialize_credit_balance
  # Ponte: ao criar/mudar assinatura, reflete o plano ATUAL da conta nas feature flags dela.
  after_save :sync_account_features

  private

  # Ciclo mensal ancorado no início da assinatura. Ai::CreditsRenewalJob avança este marco a cada
  # renovação (preservando o dia). ||= só na criação — não recalcula em updates.
  def set_initial_renewal_date
    self.next_renewal_at ||= (started_at || Time.current) + 1.month
  end

  # Inicializa plan_credits com o valor do plano logo na criação (não espera o 1º ciclo). SÓ on
  # create: resetar em updates apagaria o consumo do ciclo corrente. extra_credits (comprados
  # avulsos) nunca são tocados — build_ai_credit_balance só cria se ainda não houver saldo.
  def initialize_credit_balance
    balance = account.ai_credit_balance || account.build_ai_credit_balance
    balance.update!(plan_credits: plan.ai_credits_included)
  end

  def sync_account_features
    current_plan = account.subscriptions.current.first&.plan
    current_plan&.sync_features_to!(account)
  end
end
