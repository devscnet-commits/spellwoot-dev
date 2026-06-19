# A lead variable the agent collects during the conversation (Instruções tab). Per department.
class Ai::LeadVariable < ApplicationRecord
  VAR_TYPES = %w[texto numero booleano lista].freeze

  belongs_to :account, class_name: '::Account'
  belongs_to :department, class_name: 'Ai::Department', foreign_key: :ai_department_id

  validates :name, presence: true
  validates :var_type, inclusion: { in: VAR_TYPES }
end
