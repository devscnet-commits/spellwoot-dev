# An AI Agent (assistente virtual) — a domain entirely separate from human agents (User).
# Multiple agents may exist per account (production/staging/sandbox/experimental); `stage` is
# lifecycle metadata only — routing is decided by Ai::AgentInbox.
# == Schema Information
#
# Table name: ai_agents
#
#  id                       :bigint           not null, primary key
#  assistant_avatar         :text
#  assistant_description    :text
#  assistant_language       :string           default("pt-BR")
#  assistant_name           :string
#  assistant_personality    :text
#  assistant_voice          :string
#  base_prompt              :text
#  category                 :string
#  company_name             :string
#  guardrails               :text
#  handoff_agent_ids        :jsonb            not null
#  handoff_team_ids         :jsonb            not null
#  identify_as              :string           default("ai")
#  identity                 :jsonb            not null
#  name                     :string           not null
#  site                     :string
#  stage                    :string           default("sandbox"), not null
#  status                   :string           default("active"), not null
#  version                  :string
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#  account_id               :bigint           not null
#  ai_operation_profile_id  :bigint
#  fallback_handoff_team_id :bigint
#  team_id                  :bigint
#
# Indexes
#
#  index_ai_agents_on_account_id  (account_id)
#  index_ai_agents_on_team_id     (team_id)
#
class Ai::Agent < ApplicationRecord
  STAGES = %w[production staging sandbox experimental].freeze

  # Campos versionados (histórico + rollback) via Ai::Version polimórfico. São colunas planas, então
  # o restore SUBSTITUI cada valor (sem merge). Antes viviam em Ai::AgentVersion::SNAPSHOT_FIELDS.
  SNAPSHOT_FIELDS = %w[name assistant_name category company_name site version identify_as
                       assistant_avatar assistant_description assistant_personality
                       assistant_language assistant_voice base_prompt guardrails stage status
                       ai_operation_profile_id].freeze

  belongs_to :account, class_name: '::Account'
  belongs_to :operation_profile, class_name: 'Ai::OperationProfile',
                                  foreign_key: :ai_operation_profile_id, optional: true
  # Optional routing link: conversations assigned to this team are handled by this agent.
  belongs_to :team, class_name: '::Team', optional: true
  has_many :agent_inboxes, class_name: 'Ai::AgentInbox', foreign_key: :ai_agent_id, dependent: :destroy
  has_many :departments, class_name: 'Ai::Department', foreign_key: :ai_agent_id, dependent: :destroy

  validates :name, presence: true
  validates :stage, inclusion: { in: STAGES }
  # Every agent must point to a service level (operation profile): it defines the provider/model the
  # agent answers with. Without it the engine would fall back to defaults instead of an explicit choice.
  validates :ai_operation_profile_id, presence: { message: 'selecione um nível de atendimento' }
  # Avatar is an inline base64 data URL (downscaled on the client). This explicit limit overrides the
  # generic 20k text cap (ApplicationRecord) while still bounding the payload (~225 KB of base64).
  validates :assistant_avatar, length: { maximum: 300_000 }
  # (3) Default de give-up: o time de fallback só pode ser um dos que o agente DECLAROU poder acionar
  # (handoff_team_ids). Whitelist VAZIA = configuração ausente, NÃO permissão ampla — então qualquer
  # fallback com whitelist vazia é rejeitado (não incluído em []). Espelha o conclusion.team_unlisted, mas
  # aqui na ESCRITA (a UI já impede pelo select vazio; isto fecha o console/API).
  validate :fallback_handoff_team_in_whitelist

  scope :active, -> { where(status: 'active') }

  def fallback_handoff_team_in_whitelist
    return if fallback_handoff_team_id.blank?
    return if Array(handoff_team_ids).map(&:to_i).include?(fallback_handoff_team_id.to_i)

    errors.add(:fallback_handoff_team_id, 'deve ser um time da lista "Transferir para times" (handoff_team_ids)')
  end
end
