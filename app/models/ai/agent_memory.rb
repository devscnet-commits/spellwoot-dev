# Per-conversation memory (collected slots + rolling summary).
# == Schema Information
#
# Table name: ai_agent_memory
#
#  id              :bigint           not null, primary key
#  state           :jsonb            not null
#  summary         :text
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  ai_agent_id     :bigint           not null
#  conversation_id :bigint           not null
#
# Indexes
#
#  index_ai_agent_memory_on_conversation_id_and_ai_agent_id  (conversation_id,ai_agent_id) UNIQUE
#
class Ai::AgentMemory < ApplicationRecord
  self.table_name = 'ai_agent_memory'

  belongs_to :agent, class_name: 'Ai::Agent', foreign_key: :ai_agent_id
  belongs_to :conversation, class_name: '::Conversation', optional: true
end
