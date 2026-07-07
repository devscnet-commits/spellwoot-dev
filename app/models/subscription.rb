# == Schema Information
#
# Table name: subscriptions
#
#  id         :bigint           not null, primary key
#  ends_at    :datetime
#  started_at :datetime
#  status     :integer          default("active"), not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  account_id :bigint           not null
#  plan_id    :bigint           not null
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

  # Ponte: ao criar/mudar assinatura, reflete o plano ATUAL da conta nas feature flags dela.
  after_save :sync_account_features

  private

  def sync_account_features
    current_plan = account.subscriptions.current.first&.plan
    current_plan&.sync_features_to!(account)
  end
end
