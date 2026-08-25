# Audit row for a single tool/capability execution (or intended/pending one).
# == Schema Information
#
# Table name: ai_capability_executions
#
#  id                  :bigint           not null, primary key
#  approval_status     :string           default("not_required"), not null
#  capability_key      :string           not null
#  error               :text
#  governance          :string           default("allowed"), not null
#  input               :jsonb            not null
#  output              :jsonb            not null
#  requested_by        :string           default("ai"), not null
#  rollback_data       :jsonb            not null
#  status              :string           default("pending"), not null
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  account_id          :bigint           not null
#  ai_run_id           :bigint
#  ai_tool_id          :bigint
#  approved_by_user_id :bigint
#  conversation_id     :bigint
#
# Indexes
#
#  index_ai_capability_executions_on_account_id       (account_id)
#  index_ai_capability_executions_on_conversation_id  (conversation_id)
#  index_ai_capability_executions_on_status           (status)
#
class Ai::CapabilityExecution < ApplicationRecord
  belongs_to :account, class_name: '::Account'
  belongs_to :tool, class_name: 'Ai::Tool', foreign_key: :ai_tool_id, optional: true
  belongs_to :conversation, class_name: '::Conversation', optional: true

  STATUSES = %w[pending executed skipped failed reverted].freeze

  scope :pending_approval, -> { where(approval_status: 'pending') }
  scope :executed, -> { where(status: 'executed') }
end
