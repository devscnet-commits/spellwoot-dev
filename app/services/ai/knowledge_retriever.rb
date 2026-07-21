# RAG retrieval over pgvector (neighbor gem). Reuses the existing embedding service TECHNICALLY
# (no dependency on the Captain domain). Degrades to a simple text match if embeddings are
# unavailable, so the pipeline always records what it retrieved.
class Ai::KnowledgeRetriever
  # Quantos trechos de conhecimento entram no contexto. Baixo demais faz a IA "esconder" itens de
  # listas (ex.: só 3 planos de vários). Para listas completas (planos), prefira consolidar tudo num
  # único item de conhecimento ou no prompt — RAG por similaridade não garante trazer todos.
  TOP_K = 6

  def self.retrieve(query:, account_id:, department_id: nil)
    retrieve_scored(query: query, account_id: account_id, department_id: department_id)[:chunks]
  end

  # Like retrieve, but also returns the top cosine similarity (1 - distance) of the best candidate
  # so the routing strategy can decide cache vs cheap vs premium. top_score is nil without vectors.
  # Scope: sources of the given department PLUS account-wide shared sources (ai_department_id NULL).
  # department_id nil = legacy behavior: the whole account library (every source), so no regression.
  def self.retrieve_scored(query:, account_id:, department_id: nil)
    sources = Ai::KnowledgeSource.active.where(account_id: account_id)
    sources = sources.where(ai_department_id: [department_id, nil]) if department_id
    source_ids = sources.pluck(:id)
    return { chunks: [], top_score: nil } if source_ids.empty? || query.blank?

    scope = Ai::KnowledgeChunk.where(ai_knowledge_source_id: source_ids)
    vector = embed(query)
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

  # Embute a PERGUNTA para a busca vetorial. Ai::Embedder degrada em nil quando não há chave ou a
  # chave é inválida (auth); um erro transitório também vira nil aqui -> o retriever cai no ILIKE.
  def self.embed(text)
    Ai::Embedder.embed(text)
  rescue StandardError => e
    Rails.logger.warn "[Ai::KnowledgeRetriever] embedding indisponível: #{e.message}"
    nil
  end
end
