# Resumo da conversa gerado no momento de um handoff AUTOMÁTICO da IA para um humano (ver
# Ai::HandoffSummaryGenerator / Ai::HandoffSummaryJob). Um registro por handoff — histórico completo por
# conversa; o card na sidebar lê o mais recente. `reason` = motivo do handoff; `run` = o Ai::Run da
# geração (rastreio de custo, sem consumir crédito).
# == Schema Information
#
# Table name: ai_handoff_summaries
#
#  id              :bigint           not null, primary key
#  content         :text             not null
#  reason          :string           not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#  account_id      :bigint           not null
#  ai_run_id       :bigint
#  conversation_id :bigint           not null
#
# Indexes
#
#  index_ai_handoff_summaries_on_account_id                      (account_id)
#  index_ai_handoff_summaries_on_ai_run_id                       (ai_run_id)
#  index_ai_handoff_summaries_on_conversation_id_and_created_at  (conversation_id,created_at)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (ai_run_id => ai_runs.id)
#  fk_rails_...  (conversation_id => conversations.id) ON DELETE => cascade
#
class Ai::HandoffSummary < ApplicationRecord
  belongs_to :account, class_name: '::Account'
  belongs_to :conversation, class_name: '::Conversation'
  belongs_to :run, class_name: 'Ai::Run', foreign_key: :ai_run_id, optional: true

  validates :reason, presence: true
  validates :content, presence: true

  scope :recent, -> { order(created_at: :desc) }

  # O resumo mais recente de uma conversa (o que o card exibe), ou nil.
  def self.latest_for(conversation_id)
    where(conversation_id: conversation_id).recent.first
  end
end
