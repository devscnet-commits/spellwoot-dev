# Reuses pgvector (neighbor gem) technically — no dependency on the Captain domain.
# == Schema Information
#
# Table name: ai_knowledge_chunks
#
#  id                     :bigint           not null, primary key
#  content                :text             not null
#  embedding              :vector(1536)
#  created_at             :datetime         not null
#  updated_at             :datetime         not null
#  ai_knowledge_source_id :bigint           not null
#
# Indexes
#
#  idx_ai_knowledge_chunks_embedding                    (embedding) USING ivfflat
#  index_ai_knowledge_chunks_on_ai_knowledge_source_id  (ai_knowledge_source_id)
#
class Ai::KnowledgeChunk < ApplicationRecord
  belongs_to :knowledge_source, class_name: 'Ai::KnowledgeSource', foreign_key: :ai_knowledge_source_id

  has_neighbors :embedding
end
