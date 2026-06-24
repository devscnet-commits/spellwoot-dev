# Reuses pgvector (neighbor gem) technically — no dependency on the Captain domain.
class Ai::KnowledgeChunk < ApplicationRecord
  belongs_to :knowledge_source, class_name: 'Ai::KnowledgeSource', foreign_key: :ai_knowledge_source_id

  has_neighbors :embedding
end
