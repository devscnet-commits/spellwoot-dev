# An AI Agent (assistente virtual) — a domain entirely separate from human agents (User).
# Multiple agents may exist per account (production/staging/sandbox/experimental); `stage` is
# lifecycle metadata only — routing is decided by Ai::AgentInbox.
# == Schema Information
#
# Table name: ai_agents
#
#  id                      :bigint           not null, primary key
#  assistant_avatar        :text
#  assistant_description   :text
#  assistant_language      :string           default("pt-BR")
#  assistant_name          :string
#  assistant_personality   :text
#  assistant_voice         :string
#  base_prompt             :text
#  category                :string
#  company_name            :string
#  guardrails              :text
#  handoff_agent_ids       :jsonb            not null
#  handoff_team_ids        :jsonb            not null
#  identify_as             :string           default("ai")
#  identity                :jsonb            not null
#  name                    :string           not null
#  site                    :string
#  stage                   :string           default("sandbox"), not null
#  status                  :string           default("active"), not null
#  version                 :string
#  created_at              :datetime         not null
#  updated_at              :datetime         not null
#  account_id              :bigint           not null
#  ai_operation_profile_id :bigint
#  team_id                 :bigint
#
# Indexes
#
#  index_ai_agents_on_account_id  (account_id)
#  index_ai_agents_on_team_id     (team_id)
#
class Ai::Agent < ApplicationRecord
  STAGES = %w[production staging sandbox experimental].freeze

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

  scope :active, -> { where(status: 'active') }
end
