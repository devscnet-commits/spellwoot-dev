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
