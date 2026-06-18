# RAG retrieval over pgvector (neighbor gem). Reuses the existing embedding service TECHNICALLY
# (no dependency on the Captain domain). Degrades to a simple text match if embeddings are
# unavailable, so the pipeline always records what it retrieved.
class Ai::KnowledgeRetriever
  TOP_K = 3

  def self.retrieve(department:, query:, account_id:)
    source_ids = department.knowledge_sources.active.pluck(:id)
    return [] if source_ids.empty? || query.blank?

    scope = Ai::KnowledgeChunk.where(ai_knowledge_source_id: source_ids)
    vector = embed(query, account_id)
    if vector.present?
      scope.nearest_neighbors(:embedding, vector, distance: 'cosine').first(TOP_K).map(&:content)
    else
      scope.where('content ILIKE ?', "%#{query.to_s.first(60)}%").limit(TOP_K).pluck(:content)
    end
  rescue StandardError => e
    Rails.logger.error "[Ai::KnowledgeRetriever] #{e.class}: #{e.message}"
    []
  end

  def self.embed(text, account_id)
    return nil unless defined?(Captain::Llm::EmbeddingService)

    Captain::Llm::EmbeddingService.new(account_id: account_id).get_embedding(text)
  rescue StandardError => e
    Rails.logger.warn "[Ai::KnowledgeRetriever] embedding indisponível: #{e.message}"
    nil
  end
end
