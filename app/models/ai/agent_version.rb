# Immutable snapshot of an agent's configuration, captured on each save. Enables a visible
# history and one-click rollback. Only meaningful config fields are stored (not timestamps/ids).
# == Schema Information
#
# Table name: ai_agent_versions
#
#  id             :bigint           not null, primary key
#  note           :string
#  snapshot       :jsonb            not null
#  version_number :integer          default(1), not null
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#  account_id     :bigint           not null
#  ai_agent_id    :bigint           not null
#
# Indexes
#
#  index_ai_agent_versions_on_ai_agent_id_and_version_number  (ai_agent_id,version_number)
#
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
