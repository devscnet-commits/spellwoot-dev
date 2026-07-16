# Ingests a knowledge source into retrievable chunks: splits its text and (re)creates
# Ai::KnowledgeChunk rows, embedding each via Ai::Embedder.
#
# Robustez (não engolir mais falha de embedding em silêncio):
#   - erro TRANSITÓRIO (429/5xx/timeout/rede) PROPAGA -> Sidekiq re-tenta com backoff (retry_on).
#     Enquanto re-tenta, os chunks ANTIGOS ficam intactos (só troco tudo depois de embutir tudo).
#   - erro de AUTH (chave inválida/revogada) ou SEM chave -> degrada: grava os chunks SEM vetor
#     (o retriever cai no ILIKE) e NÃO re-tenta (retry não conserta chave errada).
#   - esgotados os retries transitórios -> degrada também (grava sem vetor; o backfill re-tenta depois).
class Ai::KnowledgeIngestJob < ApplicationJob
  queue_as :low

  CHUNK_SIZE = 800
  MAX_CHUNKS = 50
  HARD_SPLIT = /.{1,#{CHUNK_SIZE}}/m

  # Só o erro transitório re-tenta. Ao esgotar, degrada (grava sem vetor) — nunca deixa a source
  # órfã de chunks por causa de uma indisponibilidade temporária.
  retry_on Ai::Embedder::TransientError, wait: :polynomially_longer, attempts: 5 do |job, error|
    Rails.logger.warn "[Ai::KnowledgeIngestJob] embedding transitório persistiu após retries; " \
                      "gravando SEM vetor (backfill re-tenta depois): #{error.message}"
    job.send(:ingest, job.arguments.first, force_degrade: true)
  end

  def perform(source_id)
    ingest(source_id)
  end

  private

  # force_degrade: pula o embedding e grava tudo sem vetor (usado no fim dos retries).
  def ingest(source_id, force_degrade: false)
    source = Ai::KnowledgeSource.find_by(id: source_id)
    return if source.nil?

    if source.status != 'active'
      source.chunks.delete_all
      return
    end

    pieces = chunkify(source_text(source)).first(MAX_CHUNKS)
    rows = build_rows(pieces, force_degrade ? nil : Ai::Embedder.new)
    replace_chunks(source, rows)
  end

  # Embute TODOS os pieces ANTES de tocar nos chunks existentes. TransientError sobe (retry_on).
  # AuthError degrada o job inteiro: para de tentar embutir e grava o resto sem vetor.
  def build_rows(pieces, embedder)
    degrade = embedder.nil? || !embedder.enabled?
    pieces.map do |content|
      vector = nil
      unless degrade
        begin
          vector = embedder.embed(content) # TransientError NÃO é capturado aqui -> propaga -> retry
        rescue Ai::Embedder::AuthError => e
          Rails.logger.warn "[Ai::KnowledgeIngestJob] chave inválida — gravando SEM vetor: #{e.message}"
          degrade = true
        end
      end
      { content: content, embedding: vector }
    end
  end

  # Troca atômica: só apaga os chunks antigos quando os novos (com/sem vetor) já estão prontos.
  def replace_chunks(source, rows)
    Ai::KnowledgeChunk.transaction do
      source.chunks.delete_all
      rows.each { |r| source.chunks.create!(content: r[:content], embedding: r[:embedding]) }
    end
  end

  def source_text(source)
    [source.title, source.raw].map { |s| s.to_s.strip }.reject(&:blank?).uniq.join("\n")
  end

  # Split on blank lines, then pack paragraphs into ~CHUNK_SIZE pieces (hard-splitting any huge one).
  def chunkify(text)
    paragraphs = text.to_s.split(/\r?\n\s*\r?\n/).map(&:strip).reject(&:blank?)
    paragraphs = [text.to_s.strip] if paragraphs.empty? && text.to_s.strip.present?

    chunks = []
    buffer = +''
    paragraphs.each do |paragraph|
      if paragraph.length > CHUNK_SIZE
        chunks << buffer.strip if buffer.strip.present?
        buffer = +''
        paragraph.scan(HARD_SPLIT).each { |part| chunks << part.strip }
      else
        if buffer.length + paragraph.length + 1 > CHUNK_SIZE && buffer.present?
          chunks << buffer.strip
          buffer = +''
        end
        buffer << paragraph << "\n"
      end
    end
    chunks << buffer.strip if buffer.strip.present?
    chunks.reject(&:blank?)
  end
end
