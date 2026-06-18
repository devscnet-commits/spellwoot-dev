# Audit of a single model generation (provider/model/tokens/cost/latency/decision).
class Ai::Run < ApplicationRecord
  belongs_to :account, class_name: '::Account'
  belongs_to :conversation, class_name: '::Conversation', optional: true
  has_many :events, class_name: 'Ai::Event', foreign_key: :ai_run_id, dependent: :nullify
end
