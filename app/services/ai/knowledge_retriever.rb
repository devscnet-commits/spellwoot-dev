# RAG retrieval over pgvector (neighbor gem). Reuses the existing embedding service TECHNICALLY
# (no dependency on the Captain domain). Degrades to a simple text match if embeddings are
# unavailable, so the pipeline always records what it retrieved.
class Ai::KnowledgeRetriever
  # Quantos trechos de conhecimento entram no contexto. Baixo demais faz a IA "esconder" itens de
  # listas (ex.: só 3 planos de vários). Para listas completas (planos), prefira consolidar tudo num
  # único item de conhecimento ou no prompt — RAG por similaridade não garante trazer todos.
  TOP_K = 6

  # CATÁLOGO PEQUENO: quando pedem 'produto' e o total de chars dos chunks de produto cabe aqui,
  # devolvemos TODOS os produtos SEM busca vetorial (a similaridade não serve p/ catálogo — mede
  # relacionamento semântico, não "é um plano"). Acima do limite, cai na busca vetorial restrita ao kind.
  SMALL_CATALOG_CHAR_LIMIT = 4000

  # kinds: array opcional de kind de KnowledgeSource (ex.: ['produto']). Sem ele, comportamento
  # INALTERADO (retrocompat p/ Copilot/Tester).
  def self.retrieve(query:, account_id:, department_id: nil, kinds: nil)
    retrieve_scored(query: query, account_id: account_id, department_id: department_id, kinds: kinds)[:chunks]
  end

  # Like retrieve, but also returns the top cosine similarity (1 - distance) of the best candidate
  # so the routing strategy can decide cache vs cheap vs premium. top_score is nil without vectors.
  # Scope: sources of the given department PLUS account-wide shared sources (ai_department_id NULL).
  # department_id nil = legacy behavior: the whole account library (every source), so no regression.
  def self.retrieve_scored(query:, account_id:, department_id: nil, kinds: nil)
    source_ids = source_ids_for(account_id, department_id, kinds)
    return { chunks: [], top_score: nil } if source_ids.empty? || query.blank?

    # Catálogo pequeno: pediram 'produto' e todos os produtos cabem -> devolve todos, sem vetor.
    catalog = small_catalog_chunks(account_id, department_id, kinds)
    return { chunks: catalog, top_score: nil } if catalog

    search(Ai::KnowledgeChunk.where(ai_knowledge_source_id: source_ids), query)
  rescue StandardError => e
    Rails.logger.error "[Ai::KnowledgeRetriever] #{e.class}: #{e.message}"
    { chunks: [], top_score: nil }
  end

  # Sources ATIVAS da conta, do department (+ compartilhadas nil) e — quando pedido — do(s) kind(s).
  def self.source_ids_for(account_id, department_id, kinds)
    sources = Ai::KnowledgeSource.active.where(account_id: account_id)
    sources = sources.where(ai_department_id: [department_id, nil]) if department_id
    sources = sources.where(kind: kinds) if kinds.present?
    sources.pluck(:id)
  end

  # Busca vetorial (embedding + vizinhos) OU, sem vetor (sem chave/erro), o fallback ILIKE. top_score é
  # a similaridade do melhor candidato (nil sem vetor).
  def self.search(scope, query)
    vector = embed(query)
    return { chunks: scope.where('content ILIKE ?', "%#{query.to_s.first(60)}%").limit(TOP_K).pluck(:content), top_score: nil } if vector.blank?

    records = scope.nearest_neighbors(:embedding, vector, distance: 'cosine').first(TOP_K)
    distance = records.first&.neighbor_distance
    { chunks: records.map(&:content), top_score: distance.nil? ? nil : (1.0 - distance).round(4) }
  end

  # Chunks de PRODUTO (só quando 'produto' está entre os kinds pedidos), se couberem no limite —
  # senão nil (o caller cai na busca vetorial restrita ao kind). Mede só os chunks de produto, não o
  # scope inteiro: um kinds:['produto','faq'] ainda decide pelo tamanho do catálogo de produtos.
  def self.small_catalog_chunks(account_id, department_id, kinds)
    return nil unless Array(kinds).map(&:to_s).include?('produto')

    prod = Ai::KnowledgeSource.active.where(account_id: account_id, kind: 'produto')
    prod = prod.where(ai_department_id: [department_id, nil]) if department_id
    contents = Ai::KnowledgeChunk.where(ai_knowledge_source_id: prod.select(:id)).pluck(:content)
    return nil if contents.empty? || contents.sum { |c| c.to_s.length } > SMALL_CATALOG_CHAR_LIMIT

    contents
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
