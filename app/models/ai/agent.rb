# An AI Agent (assistente virtual) — a domain entirely separate from human agents (User).
# Multiple agents may exist per account (production/staging/sandbox/experimental); `stage` is
# lifecycle metadata only — routing is decided by Ai::AgentInbox.
class Ai::Agent < ApplicationRecord
  STAGES = %w[production staging sandbox experimental].freeze

  belongs_to :account, class_name: '::Account'
  belongs_to :operation_profile, class_name: 'Ai::OperationProfile',
                                  foreign_key: :ai_operation_profile_id, optional: true
  # Optional routing link: conversations assigned to this team are handled by this agent.
  belongs_to :team, class_name: '::Team', optional: true
  has_many :agent_inboxes, class_name: 'Ai::AgentInbox', foreign_key: :ai_agent_id, dependent: :destroy
  has_many :departments, class_name: 'Ai::Department', foreign_key: :ai_agent_id, dependent: :destroy

  validates :name, presence: true
  validates :stage, inclusion: { in: STAGES }

  scope :active, -> { where(status: 'active') }
end
