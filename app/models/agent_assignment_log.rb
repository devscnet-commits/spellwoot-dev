# One row per real auto-assignment decision: who was eligible, who survived rate limiting, who was
# chosen. Written by AutoAssignment::AssignmentService and AutoAssignment::AgentAssignmentService.
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
