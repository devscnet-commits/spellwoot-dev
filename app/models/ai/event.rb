# Event-driven trail of the pipeline (one row per step).
class Ai::Event < ApplicationRecord
  belongs_to :account, class_name: '::Account'
  belongs_to :run, class_name: 'Ai::Run', foreign_key: :ai_run_id, optional: true
  belongs_to :conversation, class_name: '::Conversation', optional: true
end
