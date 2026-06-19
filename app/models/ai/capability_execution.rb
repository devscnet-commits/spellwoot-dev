# Audit row for a single tool/capability execution (or intended/pending one).
class Ai::CapabilityExecution < ApplicationRecord
  belongs_to :account, class_name: '::Account'
  belongs_to :tool, class_name: 'Ai::Tool', foreign_key: :ai_tool_id, optional: true
  belongs_to :conversation, class_name: '::Conversation', optional: true

  STATUSES = %w[pending executed skipped failed reverted].freeze

  scope :pending_approval, -> { where(approval_status: 'pending') }
  scope :executed, -> { where(status: 'executed') }
end
