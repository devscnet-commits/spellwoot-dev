class Ai::KnowledgeSource < ApplicationRecord
  belongs_to :account, class_name: '::Account'
  belongs_to :department, class_name: 'Ai::Department', foreign_key: :ai_department_id, optional: true
  has_many :chunks, class_name: 'Ai::KnowledgeChunk', foreign_key: :ai_knowledge_source_id, dependent: :destroy

  scope :active, -> { where(status: 'active') }
end
