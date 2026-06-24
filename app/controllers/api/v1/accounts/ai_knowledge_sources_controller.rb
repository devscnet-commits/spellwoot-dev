# CRUD for the account's shared knowledge library, with chunking + embedding ingestion (RAG).
# Account-level: a single library every agent draws from, ingested once. Reuses the embedding
# service technically; if unavailable, chunks are stored without vectors (retrieval falls back to text).
class Api::V1::Accounts::AiKnowledgeSourcesController < Api::V1::Accounts::BaseController
  before_action :set_source, only: %i[update destroy]

  def index
    render json: scope.order(:id).map { |source| serialize(source) }
  end

  def create
    source = scope.new(source_params.merge(account_id: Current.account.id))
    return render(json: { errors: source.errors.full_messages }, status: :unprocessable_entity) unless source.save

    ingest(source)
    render json: serialize(source), status: :created
  end

  def update
    raw_changed = source_params[:raw].present? && source_params[:raw] != @source.raw
    return render(json: { errors: @source.errors.full_messages }, status: :unprocessable_entity) unless @source.update(source_params)

    ingest(@source) if raw_changed
    render json: serialize(@source)
  end

  def destroy
    @source.destroy!
    head :no_content
  end

  private

  def scope
    ::Ai::KnowledgeSource.where(account_id: Current.account.id)
  end

  def set_source
    @source = scope.find_by(id: params[:id])
    render(json: { error: 'fonte não encontrada' }, status: :not_found) if @source.nil?
  end

  def source_params
    params.require(:ai_knowledge_source).permit(:kind, :title, :raw, :status)
  end

  def ingest(source)
    source.chunks.delete_all
    pieces = source.raw.to_s.split(/\n\s*\n/).map(&:strip).reject(&:blank?)
    pieces = [source.raw.to_s.strip] if pieces.empty? && source.raw.present?
    pieces.each { |content| source.chunks.create!(content: content, embedding: embed(content).presence) }
  end

  def embed(text)
    return nil unless defined?(Captain::Llm::EmbeddingService)

    Captain::Llm::EmbeddingService.new(account_id: Current.account.id).get_embedding(text)
  rescue StandardError => e
    Rails.logger.warn "[AiKnowledge] embedding indisponível: #{e.message}"
    nil
  end

  def serialize(source)
    source.as_json.merge('chunks_count' => source.chunks.count)
  end
end
