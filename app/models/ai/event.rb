# Event-driven trail of the pipeline (one row per step).
# == Schema Information
#
# Table name: ai_events
#
#  id              :bigint           not null, primary key
#  event_type      :string           not null
#  payload         :jsonb            not null
#  status          :string           default("ok"), not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  account_id      :bigint           not null
#  ai_run_id       :bigint
#  conversation_id :bigint
#  parent_event_id :bigint
#
# Indexes
#
#  index_ai_events_on_ai_run_id        (ai_run_id)
#  index_ai_events_on_conversation_id  (conversation_id)
#
class Ai::Event < ApplicationRecord
  belongs_to :account, class_name: '::Account'
  belongs_to :run, class_name: 'Ai::Run', foreign_key: :ai_run_id, optional: true
  belongs_to :conversation, class_name: '::Conversation', optional: true
end
