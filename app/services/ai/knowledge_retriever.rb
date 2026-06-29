# RAG retrieval over pgvector (neighbor gem). Reuses the existing embedding service TECHNICALLY
# (no dependency on the Captain domain). Degrades to a simple text match if embeddings are
# unavailable, so the pipeline always records what it retrieved.
class Ai::KnowledgeRetriever
  # Quantos trechos de conhecimento entram no contexto. Baixo demais faz a IA "esconder" itens de
  # listas (ex.: só 3 planos de vários). Para listas completas (planos), prefira consolidar tudo num
  # único item de conhecimento ou no prompt — RAG por similaridade não garante trazer todos.
  TOP_K = 6

  def self.retrieve(query:, account_id:)
    retrieve_scored(query: query, account_id: account_id)[:chunks]
  end

  # Like retrieve, but also returns the top cosine similarity (1 - distance) of the best candidate
  # so the routing strategy can decide cache vs cheap vs premium. top_score is nil without vectors.
  # Knowledge is account-wide (shared library): every agent draws from the same sources, ingested once.
  def self.retrieve_scored(query:, account_id:)
    source_ids = Ai::KnowledgeSource.active.where(account_id: account_id).pluck(:id)
    return { chunks: [], top_score: nil } if source_ids.empty? || query.blank?

    scope = Ai::KnowledgeChunk.where(ai_knowledge_source_id: source_ids)
    vector = embed(query, account_id)
    if vector.present?
      records = scope.nearest_neighbors(:embedding, vector, distance: 'cosine').first(TOP_K)
      distance = records.first&.neighbor_distance
      score = distance.nil? ? nil : (1.0 - distance).round(4)
      { chunks: records.map(&:content), top_score: score }
    else
      chunks = scope.where('content ILIKE ?', "%#{query.to_s.first(60)}%").limit(TOP_K).pluck(:content)
      { chunks: chunks, top_score: nil }
    end
  rescue StandardError => e
    Rails.logger.error "[Ai::KnowledgeRetriever] #{e.class}: #{e.message}"
    { chunks: [], top_score: nil }
  end

  def self.embed(text, account_id)
    return nil unless defined?(Captain::Llm::EmbeddingService)

    Captain::Llm::EmbeddingService.new(account_id: account_id).get_embedding(text)
  rescue StandardError => e
    Rails.logger.warn "[Ai::KnowledgeRetriever] embedding indisponível: #{e.message}"
    nil
  end
end
