# Auto-cura: rede de segurança periódica para chunks de conhecimento que ficaram SEM embedding
# (ex.: uma queda transitória da API que esgotou os retries, ou legado gerado quando a chave estava
# quebrada). Reenfileira o Ai::KnowledgeIngestJob para essas sources — quando a API/chave voltam ao
# normal, o embedding é gerado sozinho, sem ninguém rodar comando.
#
# Idempotência (sem lock distribuído — YAGNI): só pega sources com updated_at < STALE_WINDOW atrás,
# evitando reprocessar uma que acabou de ser tocada (criação/edição) e cujo ingest provavelmente
# ainda está rodando/enfileirado. Bounded em BATCH por execução; o cron repete até drenar.
class Ai::EmbeddingBackfillJob < ApplicationJob
  queue_as :scheduled_jobs

  BATCH = 50
  # STALE_WINDOW precisa ser maior que o tempo cumulativo de backoff do
  # retry_on em Ai::KnowledgeIngestJob (polynomially_longer, 5 attempts).
  # Se esses parâmetros do job de ingest mudarem, revisar esta janela —
  # senão o backfill pode reenfileirar uma source que ainda está em
  # backoff aguardando retry, gerando dois jobs concorrentes.
  STALE_WINDOW = 10.minutes

  def perform
    return unless Ai::Embedder.new.enabled? # sem chave configurada: não adianta re-tentar

    source_ids = stale_sources_missing_embedding
    source_ids.each { |id| Ai::KnowledgeIngestJob.perform_later(id) }
    Rails.logger.info "[Ai::EmbeddingBackfillJob] reenfileiradas #{source_ids.size} sources sem embedding" if source_ids.any?
  end

  private

  # Sources ATIVAS que têm pelo menos um chunk sem embedding e que NÃO foram tocadas nos últimos
  # STALE_WINDOW (evita corrida com um ingest recém-disparado).
  def stale_sources_missing_embedding
    Ai::KnowledgeSource
      .active
      .where(id: Ai::KnowledgeChunk.where(embedding: nil).select(:ai_knowledge_source_id))
      .where('ai_knowledge_sources.updated_at < ?', STALE_WINDOW.ago)
      .order(:id)
      .limit(BATCH)
      .pluck(:id)
  end
end
