# Audit of a single model generation (provider/model/tokens/cost/latency/decision).
# == Schema Information
#
# Table name: ai_runs
#
#  id               :bigint           not null, primary key
#  cost             :decimal(12, 6)   default(0.0), not null
#  decision         :jsonb            not null
#  error_type       :string
#  knowledge_count  :integer          default(0), not null
#  latency_ms       :integer
#  mode             :string           default("shadow"), not null
#  model            :string
#  provider         :string
#  routing_band     :string
#  run_type         :string           default("decision"), not null
#  status           :string           default("recorded"), not null
#  tokens_in        :integer          default(0), not null
#  tokens_out       :integer          default(0), not null
#  worker           :string
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  account_id       :bigint           not null
#  ai_agent_id      :bigint
#  ai_department_id :bigint
#  conversation_id  :bigint
#  inbox_id         :bigint
#
# Indexes
#
#  index_ai_runs_on_account_id        (account_id)
#  index_ai_runs_on_ai_department_id  (ai_department_id)
#  index_ai_runs_on_conversation_id   (conversation_id)
#  index_ai_runs_on_inbox_id          (inbox_id)
#
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
