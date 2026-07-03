# Persistent memory of a CONTACT across conversations (vs. Ai::AgentMemory, which is per-conversation).
# One row per contact: a rolling `summary` + structured `key_facts` the supervisor reuses so it stops
# re-asking known data. Upserted by Ai::CustomerMemoryUpdater on conversation.resolved.
# == Schema Information
#
# Table name: ai_customer_memories
#
#  id                  :bigint           not null, primary key
#  conversations_count :integer          default(0), not null
#  key_facts           :jsonb            not null
#  last_updated_at     :datetime
#  summary             :text
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  account_id          :bigint           not null
#  contact_id          :bigint           not null
#
# Indexes
#
#  index_ai_customer_memories_on_account_id                 (account_id)
#  index_ai_customer_memories_on_contact_id_and_account_id  (contact_id,account_id) UNIQUE
#
class Ai::CustomerMemory < ApplicationRecord
  self.table_name = 'ai_customer_memories'

  belongs_to :account, class_name: '::Account'
  belongs_to :contact, class_name: '::Contact'

  validates :contact_id, uniqueness: { scope: :account_id }

  # True once the updater has written a summary or any fact — used by the front to hide the empty card.
  def present_for_display?
    summary.present? || key_facts.present?
  end
end
