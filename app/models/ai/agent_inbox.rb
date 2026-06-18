# Binds an AI agent to an inbox and defines HOW it acts there:
#   live   -> responds to the customer
#   shadow -> only observes and records (no side effects)
class Ai::AgentInbox < ApplicationRecord
  MODES = %w[live shadow].freeze

  belongs_to :agent, class_name: 'Ai::Agent', foreign_key: :ai_agent_id
  belongs_to :inbox, class_name: '::Inbox'

  validates :mode, inclusion: { in: MODES }

  scope :live, -> { where(mode: 'live', active: true) }
  scope :shadow, -> { where(mode: 'shadow', active: true) }
end
