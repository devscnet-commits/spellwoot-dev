# RAG retrieval over pgvector (neighbor gem). Reuses the existing embedding service TECHNICALLY
# (no dependency on the Captain domain). Degrades to a simple text match if embeddings are
# unavailable, so the pipeline always records what it retrieved.
class Ai::KnowledgeRetriever
  # Quantos trechos de conhecimento entram no contexto. Baixo demais faz a IA "esconder" itens de
  # listas (ex.: só 3 planos de vários). Para listas completas (planos), prefira consolidar tudo num
  # único item de conhecimento ou no prompt — RAG por similaridade não garante trazer todos.
  TOP_K = 6

  # FONTE PEQUENA: quando um ou mais kinds são PEDIDOS e o total de chars dos chunks desses kinds cabe
  # aqui, devolvemos TODOS SEM busca vetorial (a similaridade não serve p/ listas — mede relacionamento
  # semântico, não "pertence ao kind"). Acima do limite, cai na busca vetorial restrita ao(s) kind(s).
  SMALL_CATALOG_CHAR_LIMIT = 4000

  # kinds: array opcional de kind de KnowledgeSource (ex.: ['produto']). Sem ele, comportamento
  # INALTERADO (retrocompat p/ Copilot/Tester).
  # list_all: intenção EXPLÍCITA de "trazer todos os itens deste tipo" (ex.: lista de planos/convênios).
  # Só nesse modo o small_catalog roda (devolve tudo do kind, SEM similaridade); default false = busca
  # SEMPRE por similaridade, mesmo em conjunto pequeno.
  def self.retrieve(query:, account_id:, agent_id: nil, kinds: nil, list_all: false)
    retrieve_scored(query: query, account_id: account_id, agent_id: agent_id,
                    kinds: kinds, list_all: list_all)[:chunks]
  end

  # Like retrieve, but also returns the top cosine similarity (1 - distance) of the best candidate
  # so the routing strategy can decide cache vs cheap vs premium. top_score is nil without vectors.
  # Scope: sources of the given agent PLUS account-wide shared sources (ai_agent_id NULL).
  # agent_id nil = legacy behavior: the whole account library (every source), so no regression.
  def self.retrieve_scored(query:, account_id:, agent_id: nil, kinds: nil, list_all: false)
    source_ids = source_ids_for(account_id, agent_id, kinds)
    return { chunks: [], top_score: nil } if source_ids.empty? || query.blank?

    # list_all (conserto conv 397): SÓ com a intenção explícita de "trazer todos" o small_catalog roda.
    # Uma consulta DIRIGIDA (list_all false) NÃO pode virar "lista tudo" só porque o corpus é pequeno —
    # antes o atalho disparava por TAMANHO, misturando fontes do kind e mudando de comportamento quando o
    # conhecimento crescia. Sem list_all, sempre similaridade.
    if list_all
      catalog = small_catalog_chunks(account_id, agent_id, kinds)
      return { chunks: catalog, top_score: nil } if catalog
    end

    search(Ai::KnowledgeChunk.where(ai_knowledge_source_id: source_ids), query)
  rescue StandardError => e
    Rails.logger.error "[Ai::KnowledgeRetriever] #{e.class}: #{e.message}"
    { chunks: [], top_score: nil }
  end

  # Sources ATIVAS da conta, do agent (+ compartilhadas nil) e — quando pedido — do(s) kind(s).
  def self.source_ids_for(account_id, agent_id, kinds)
    sources = Ai::KnowledgeSource.active.where(account_id: account_id)
    sources = sources.where(ai_agent_id: [agent_id, nil]) if agent_id
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

  # Chunks dos kinds PEDIDOS, se couberem no limite — senão nil (o caller cai na busca vetorial). SÓ é
  # chamado no modo list_all (intenção "trazer todos deste tipo"); NUNCA numa consulta dirigida. Genérico
  # p/ QUALQUER kind (nenhum kind em código). Acima do limite -> nil (o dump viraria caro): cai no vetor.
  def self.small_catalog_chunks(account_id, agent_id, kinds)
    ks = Array(kinds).map(&:to_s).reject(&:blank?)
    return nil if ks.empty?

    sources = Ai::KnowledgeSource.active.where(account_id: account_id, kind: ks)
    sources = sources.where(ai_agent_id: [agent_id, nil]) if agent_id
    contents = Ai::KnowledgeChunk.where(ai_knowledge_source_id: sources.select(:id)).pluck(:content)
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
