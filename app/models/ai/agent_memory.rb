# Per-conversation memory (collected slots + rolling summary).
class Ai::AgentMemory < ApplicationRecord
  self.table_name = 'ai_agent_memory'

  belongs_to :agent, class_name: 'Ai::Agent', foreign_key: :ai_agent_id
  belongs_to :conversation, class_name: '::Conversation', optional: true
end
