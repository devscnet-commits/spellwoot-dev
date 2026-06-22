# Audit of a single model generation (provider/model/tokens/cost/latency/decision).
class Ai::Run < ApplicationRecord
  # Structured failure reasons surfaced by Shadow (F1.0/E). Populated by the Gateway (F1.1).
  ERROR_TYPES = %w[
    provider_timeout provider_error knowledge_timeout tool_failed
    guardrail_blocked budget_exceeded classification_failed unknown
  ].freeze

  belongs_to :account, class_name: '::Account'
  belongs_to :conversation, class_name: '::Conversation', optional: true
  belongs_to :department, class_name: 'Ai::Department', foreign_key: :ai_department_id, optional: true
  belongs_to :inbox, class_name: '::Inbox', optional: true
  has_many :events, class_name: 'Ai::Event', foreign_key: :ai_run_id, dependent: :nullify

  validates :error_type, inclusion: { in: ERROR_TYPES }, allow_nil: true
end
