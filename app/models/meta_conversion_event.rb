# Audit record of a Meta Conversions API send. One row per attempt (sent/failed/error), keeping the
# payload and Meta's response so conversions can be reconciled later. See Meta::ConversionsApiService.
class MetaConversionEvent < ApplicationRecord
  belongs_to :account
  belongs_to :conversation

  STATUSES = %w[sent failed error].freeze

  validates :event_name, presence: true
  validates :status, inclusion: { in: STATUSES }
end
