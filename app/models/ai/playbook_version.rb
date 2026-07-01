# Immutable snapshot of a department playbook (objetivo/steps/transfer/close/messages), captured
# on each save. Enables history and rollback per department, independent of the agent identity.
# == Schema Information
#
# Table name: ai_playbook_versions
#
#  id               :bigint           not null, primary key
#  note             :string
#  snapshot         :jsonb            not null
#  version_number   :integer          default(1), not null
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  account_id       :bigint           not null
#  ai_department_id :bigint           not null
#  ai_playbook_id   :bigint
#
# Indexes
#
#  idx_on_ai_department_id_version_number_5c61c735ff  (ai_department_id,version_number)
#
class Ai::PlaybookVersion < ApplicationRecord
  belongs_to :account, class_name: '::Account'
  belongs_to :department, class_name: 'Ai::Department', foreign_key: :ai_department_id

  SNAPSHOT_FIELDS = %w[objetivo steps transfer_when close_when default_messages].freeze

  scope :recent, -> { order(version_number: :desc) }

  def self.snapshot!(playbook, note: nil)
    data = playbook.attributes.slice(*SNAPSHOT_FIELDS)
    last = where(ai_department_id: playbook.ai_department_id).recent.first
    return last if last && last.snapshot == data && note.nil?

    create!(account_id: playbook.department.account_id, ai_department_id: playbook.ai_department_id,
            ai_playbook_id: playbook.id, note: note,
            version_number: last ? last.version_number + 1 : 1, snapshot: data)
  end
end
