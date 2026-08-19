# Binds an AI agent to an inbox and defines HOW it acts there:
#   live   -> responds to the customer
#   shadow -> only observes and records (no side effects)
# == Schema Information
#
# Table name: ai_agent_inboxes
#
#  id          :bigint           not null, primary key
#  active      :boolean          default(TRUE), not null
#  mode        :string           default("shadow"), not null
#  priority    :integer          default(1), not null
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#  ai_agent_id :bigint           not null
#  inbox_id    :bigint           not null
#
# Indexes
#
#  index_ai_agent_inboxes_on_ai_agent_id_and_inbox_id  (ai_agent_id,inbox_id) UNIQUE
#  index_ai_agent_inboxes_on_inbox_id_and_mode         (inbox_id,mode)
#
class Ai::AgentInbox < ApplicationRecord
  MODES = %w[live shadow].freeze

  belongs_to :agent, class_name: 'Ai::Agent', foreign_key: :ai_agent_id
  belongs_to :inbox, class_name: '::Inbox'

  validates :mode, inclusion: { in: MODES }

  # Achado ao vivo (19/08): "Inativo" no agente (Ai::Agent#status) não desligava NADA em tempo real —
  # só essa própria coluna active/mode do binding é que mandava. Um agente marcado "Inativo" que
  # continuasse com a caixa marcada em "Atendimento IA" seguia respondendo o cliente normalmente (e
  # ainda bloqueava a auto-atribuição humana via Conversation#ai_pending_handoff?, que só olha pra
  # este binding). agent_active fecha esse buraco: reusa Ai::Agent.active (existia, mas nunca era
  # usado por ninguém).
  scope :agent_active, -> { joins(:agent).merge(Ai::Agent.active) }
  scope :live, -> { where(mode: 'live', active: true).agent_active }
  scope :shadow, -> { where(mode: 'shadow', active: true).agent_active }
end
