# One row per real auto-assignment decision: who was eligible, who survived rate limiting, who was
# chosen. Written by AutoAssignment::AssignmentService and AutoAssignment::AgentAssignmentService.
# == Schema Information
#
# Table name: agent_assignment_logs
#
#  id                  :bigint           not null, primary key
#  available_agent_ids :jsonb            not null
#  eligible_agent_ids  :jsonb            not null
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  account_id          :bigint           not null
#  assigned_agent_id   :bigint
#  conversation_id     :bigint           not null
#  inbox_id            :bigint           not null
#
# Indexes
#
#  index_agent_assignment_logs_on_account_id               (account_id)
#  index_agent_assignment_logs_on_assigned_agent_id        (assigned_agent_id)
#  index_agent_assignment_logs_on_conversation_id          (conversation_id)
#  index_agent_assignment_logs_on_inbox_id_and_created_at  (inbox_id,created_at)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (assigned_agent_id => users.id)
#  fk_rails_...  (conversation_id => conversations.id)
#  fk_rails_...  (inbox_id => inboxes.id)
#
class AgentAssignmentLog < ApplicationRecord
  belongs_to :account
  belongs_to :inbox
  belongs_to :conversation
  belongs_to :assigned_agent, class_name: 'User', optional: true

  # Never let a logging failure break a real assignment — this table is instrumentation, not the
  # money path.
  def self.record!(inbox:, conversation:, eligible_agent_ids:, available_agent_ids:, assigned_agent_id:)
    create!(
      account_id: inbox.account_id,
      inbox_id: inbox.id,
      conversation_id: conversation.id,
      eligible_agent_ids: eligible_agent_ids,
      available_agent_ids: available_agent_ids,
      assigned_agent_id: assigned_agent_id
    )
  rescue StandardError => e
    Rails.logger.error "[AgentAssignmentLog] failed to record assignment decision: #{e.message}"
  end
end
