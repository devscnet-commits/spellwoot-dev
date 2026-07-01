# Structured playbook. The user fills structure (objetivo/steps/transfer_when/close_when/messages)
# and the system compiles it into the final prompt — the user never writes raw prompt.
# == Schema Information
#
# Table name: ai_playbooks
#
#  id               :bigint           not null, primary key
#  active           :boolean          default(TRUE), not null
#  close_when       :jsonb            not null
#  default_messages :jsonb            not null
#  objetivo         :text
#  steps            :jsonb            not null
#  transfer_when    :jsonb            not null
#  version          :integer          default(1), not null
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  ai_department_id :bigint           not null
#
# Indexes
#
#  index_ai_playbooks_on_ai_department_id  (ai_department_id)
#
class Ai::Playbook < ApplicationRecord
  belongs_to :department, class_name: 'Ai::Department', foreign_key: :ai_department_id
end
