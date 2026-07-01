# A lead variable the agent collects during the conversation (Instruções tab). Per department.
# == Schema Information
#
# Table name: ai_lead_variables
#
#  id                    :bigint           not null, primary key
#  description           :text
#  name                  :string           not null
#  position              :integer          default(0), not null
#  values                :jsonb            not null
#  var_type              :string           default("texto"), not null
#  visible_in_first_chat :boolean          default(FALSE), not null
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#  account_id            :bigint           not null
#  ai_department_id      :bigint           not null
#
# Indexes
#
#  index_ai_lead_variables_on_ai_department_id  (ai_department_id)
#
class Ai::LeadVariable < ApplicationRecord
  VAR_TYPES = %w[texto numero booleano lista].freeze

  belongs_to :account, class_name: '::Account'
  belongs_to :department, class_name: 'Ai::Department', foreign_key: :ai_department_id

  validates :name, presence: true
  validates :var_type, inclusion: { in: VAR_TYPES }
end
