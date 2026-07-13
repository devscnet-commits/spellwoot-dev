# == Schema Information
#
# Table name: ai_credit_requests
#
#  id               :bigint           not null, primary key
#  amount_requested :integer          not null
#  reason           :text
#  review_note      :text
#  reviewed_at      :datetime
#  status           :integer          default("pending"), not null
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  account_id       :bigint           not null
#  approved_by_id   :bigint
#  requested_by_id  :bigint           not null
#
# Indexes
#
#  index_ai_credit_requests_on_account_id       (account_id)
#  index_ai_credit_requests_on_approved_by_id   (approved_by_id)
#  index_ai_credit_requests_on_requested_by_id  (requested_by_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (approved_by_id => users.id)
#  fk_rails_...  (requested_by_id => users.id)
#
# Solicitação do cliente por mais créditos de IA (billing Fase 1). Fila de aprovação manual da SCNET
# (super_admin): pending -> approved (credita extra_credits) | rejected. Ver ai_credit_request_mailer +
# SuperAdmin::CreditRequestsController. A transição de estado vive nos métodos approve!/reject! (Commit 3).
class AiCreditRequest < ApplicationRecord
  belongs_to :account
  belongs_to :requested_by, class_name: 'User'
  belongs_to :approved_by, class_name: 'User', optional: true

  enum status: { pending: 0, approved: 1, rejected: 2 }

  validates :amount_requested, numericality: { only_integer: true, greater_than: 0 }
  # Uma solicitação pendente por conta de cada vez — evita fila duplicada e pedido em dobro pela UI.
  validate :single_pending_per_account, on: :create

  scope :recent_first, -> { order(created_at: :desc) }

  private

  def single_pending_per_account
    return if account_id.blank?

    scope = AiCreditRequest.where(account_id: account_id, status: :pending)
    scope = scope.where.not(id: id) if persisted?
    errors.add(:base, 'Já existe uma solicitação de créditos pendente para esta conta.') if scope.exists?
  end
end
