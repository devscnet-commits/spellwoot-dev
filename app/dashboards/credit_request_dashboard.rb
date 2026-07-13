require 'administrate/base_dashboard'

# Painel super_admin (SCNET) para a fila de solicitações de créditos de IA. Aprovar/Rejeitar são
# ações custom (ver SuperAdmin::CreditRequestsController + views/super_admin/credit_requests/show).
class CreditRequestDashboard < Administrate::BaseDashboard
  ATTRIBUTE_TYPES = {
    id: Field::Number,
    account: Field::BelongsTo,
    requested_by: Field::BelongsTo.with_options(class_name: 'User'),
    approved_by: Field::BelongsTo.with_options(class_name: 'User'),
    amount_requested: Field::Number,
    status: Field::Select.with_options(collection: AiCreditRequest.statuses.keys),
    reason: Field::Text,
    review_note: Field::Text,
    reviewed_at: Field::DateTime,
    created_at: Field::DateTime,
    updated_at: Field::DateTime
  }.freeze

  COLLECTION_ATTRIBUTES = %i[id account amount_requested status requested_by created_at].freeze

  SHOW_PAGE_ATTRIBUTES = %i[
    id account requested_by amount_requested reason status approved_by review_note reviewed_at created_at updated_at
  ].freeze

  FORM_ATTRIBUTES = %i[status review_note].freeze

  COLLECTION_FILTERS = {
    pending: ->(resources) { resources.pending },
    approved: ->(resources) { resources.approved },
    rejected: ->(resources) { resources.rejected }
  }.freeze

  def display_resource(credit_request)
    "Solicitação ##{credit_request.id} — conta #{credit_request.account_id}"
  end
end
