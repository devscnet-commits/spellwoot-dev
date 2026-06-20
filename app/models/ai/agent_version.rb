# Immutable snapshot of an agent's configuration, captured on each save. Enables a visible
# history and one-click rollback. Only meaningful config fields are stored (not timestamps/ids).
class Ai::AgentVersion < ApplicationRecord
  belongs_to :account, class_name: '::Account'
  belongs_to :agent, class_name: 'Ai::Agent', foreign_key: :ai_agent_id

  SNAPSHOT_FIELDS = %w[name assistant_name category company_name site version identify_as
                       assistant_avatar assistant_description assistant_personality
                       assistant_language assistant_voice base_prompt guardrails stage status
                       ai_operation_profile_id].freeze

  scope :recent, -> { order(version_number: :desc) }

  # Records a new version unless the config is identical to the latest one (avoids noise).
  def self.snapshot!(agent, note: nil)
    data = agent.attributes.slice(*SNAPSHOT_FIELDS)
    last = where(ai_agent_id: agent.id).recent.first
    return last if last && last.snapshot == data && note.nil?

    create!(account_id: agent.account_id, ai_agent_id: agent.id, note: note,
            version_number: last ? last.version_number + 1 : 1, snapshot: data)
  end
end
