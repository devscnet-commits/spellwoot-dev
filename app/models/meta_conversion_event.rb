# Audit record of a Meta Conversions API send. One row per attempt (sent/failed/error), keeping the
# payload and Meta's response so conversions can be reconciled later. See Meta::ConversionsApiService.
# == Schema Information
#
# Table name: meta_conversion_events
#
#  id              :bigint           not null, primary key
#  event_name      :string           not null
#  payload         :jsonb
#  response        :text
#  status          :string           not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  account_id      :bigint           not null
#  conversation_id :bigint           not null
#  event_id        :string
#
# Indexes
#
#  index_meta_conversion_events_on_account_id                 (account_id)
#  index_meta_conversion_events_on_account_id_and_created_at  (account_id,created_at)
#  index_meta_conversion_events_on_conversation_id            (conversation_id)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (conversation_id => conversations.id)
#
class MetaConversionEvent < ApplicationRecord
  belongs_to :account
  belongs_to :conversation

  STATUSES = %w[sent failed error].freeze

  validates :event_name, presence: true
  validates :status, inclusion: { in: STATUSES }
end
