# One pipeline stage change of a conversation (kanban card). source tells who moved it:
# manual (drag on the board), result (won/lost picked in the conversation), automation, auto
# (entered the pipeline through its team) or backfill.
# == Schema Information
#
# Table name: conversation_stage_events
#
#  id                  :bigint           not null, primary key
#  source              :string           default("manual"), not null
#  created_at          :datetime         not null
#  account_id          :bigint           not null
#  conversation_id     :bigint           not null
#  from_stage_id       :bigint
#  operational_flow_id :bigint           not null
#  to_stage_id         :bigint
#  user_id             :bigint
#
# Indexes
#
#  idx_stage_events_conversation_created           (conversation_id,created_at)
#  idx_stage_events_flow_created                   (operational_flow_id,created_at)
#  index_conversation_stage_events_on_account_id   (account_id)
#  index_conversation_stage_events_on_to_stage_id  (to_stage_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id) ON DELETE => cascade
#  fk_rails_...  (conversation_id => conversations.id) ON DELETE => cascade
#  fk_rails_...  (from_stage_id => resolution_states.id) ON DELETE => nullify
#  fk_rails_...  (operational_flow_id => operational_flows.id) ON DELETE => cascade
#  fk_rails_...  (to_stage_id => resolution_states.id) ON DELETE => nullify
#
class ConversationStageEvent < ApplicationRecord
  SOURCES = %w[manual result automation auto backfill].freeze

  belongs_to :account
  belongs_to :conversation
  belongs_to :operational_flow
  belongs_to :from_stage, class_name: 'ResolutionState', optional: true
  belongs_to :to_stage, class_name: 'ResolutionState', optional: true
  belongs_to :user, optional: true

  validates :source, inclusion: { in: SOURCES }
end
