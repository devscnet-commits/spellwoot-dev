# == Schema Information
#
# Table name: conversation_result_events
#
#  id                   :bigint           not null, primary key
#  event_type           :string           default("set"), not null
#  ip_address           :string
#  previous_result      :integer
#  result               :integer          default("none"), not null
#  result_canonical_key :string
#  result_category      :string
#  result_reason        :string
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  account_id           :bigint           not null
#  conversation_id      :bigint           not null
#  inbox_id             :bigint
#  team_id              :bigint
#  user_id              :bigint
#
# Indexes
#
#  idx_cre_account_created                              (account_id,created_at)
#  idx_cre_conversation_created                         (conversation_id,created_at)
#  index_conversation_result_events_on_conversation_id  (conversation_id)
#
# Foreign Keys
#
#  fk_rails_...  (conversation_id => conversations.id)
#
class ConversationResultEvent < ApplicationRecord
  belongs_to :conversation
  belongs_to :account
  belongs_to :inbox, optional: true
  belongs_to :team, optional: true
  belongs_to :user, optional: true

  enum result: { none: 0, won: 1, lost: 2 }, _prefix: :result
  enum previous_result: { none: 0, won: 1, lost: 2 }, _prefix: :previous_result

  validates :event_type, presence: true
end
