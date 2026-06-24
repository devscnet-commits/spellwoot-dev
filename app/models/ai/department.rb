# A department is a configurable mini operational process under a single AI agent.
class Ai::Department < ApplicationRecord
  belongs_to :account, class_name: '::Account'
  belongs_to :agent, class_name: 'Ai::Agent', foreign_key: :ai_agent_id
  has_one :playbook, -> { where(active: true) }, class_name: 'Ai::Playbook', foreign_key: :ai_department_id
  has_many :tools, class_name: 'Ai::Tool', foreign_key: :ai_department_id
  has_many :knowledge_sources, class_name: 'Ai::KnowledgeSource', foreign_key: :ai_department_id
  has_many :lead_variables, class_name: 'Ai::LeadVariable', foreign_key: :ai_department_id
  has_many :department_integrations, class_name: 'Ai::DepartmentIntegration', foreign_key: :ai_department_id
  has_many :integration_links, through: :department_integrations, source: :integration_link
  has_many :department_inboxes, class_name: 'Ai::DepartmentInbox', foreign_key: :ai_department_id

  scope :active, -> { where(status: 'active') }
end
