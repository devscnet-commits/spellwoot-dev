# Ingests a knowledge source into retrievable chunks: splits its text and (re)creates
# Ai::KnowledgeChunk rows, embedding each when an embedding service is available. Without
# embeddings the chunks still serve the retriever's ILIKE fallback (content match).
class Ai::KnowledgeIngestJob < ApplicationJob
  queue_as :low

  CHUNK_SIZE = 800
  MAX_CHUNKS = 50

  def perform(source_id)
    source = Ai::KnowledgeSource.find_by(id: source_id)
    return if source.nil?

    if source.status != 'active'
      source.chunks.delete_all
      return
    end

    pieces = chunkify(source_text(source)).first(MAX_CHUNKS)
    source.chunks.delete_all
    pieces.each do |content|
      source.chunks.create!(content: content, embedding: embed(content, source.account_id))
    end
  rescue StandardError => e
    Rails.logger.error "[Ai::KnowledgeIngestJob] source=#{source_id} #{e.class}: #{e.message}"
  end

  private

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
        paragraph.scan(/.{1,#{CHUNK_SIZE}}/m).each { |part| chunks << part.strip }
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

  def embed(text, account_id)
    return nil unless defined?(Captain::Llm::EmbeddingService)

    Captain::Llm::EmbeddingService.new(account_id: account_id).get_embedding(text)
  rescue StandardError => e
    Rails.logger.warn "[Ai::KnowledgeIngestJob] embedding indisponível: #{e.message}"
    nil
  end
end
