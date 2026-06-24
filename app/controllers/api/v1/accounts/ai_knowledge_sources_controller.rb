# CRUD for a department's knowledge sources, with chunking + embedding ingestion (RAG).
# Nested under ai_agents -> ai_departments. Reuses the embedding service technically; if it is
# unavailable, chunks are stored without vectors (retrieval falls back to text match).
class Api::V1::Accounts::AiKnowledgeSourcesController < Api::V1::Accounts::BaseController
  before_action :set_department
  before_action :set_source, only: %i[update destroy]

  def index
    render json: @department.knowledge_sources.order(:id).map { |source| serialize(source) }
  end

  def create
    source = @department.knowledge_sources.new(source_params.merge(account_id: Current.account.id))
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

  def set_department
    agent = ::Ai::Agent.find_by(id: params[:ai_agent_id], account_id: Current.account.id)
    @department = agent&.departments&.find_by(id: params[:ai_department_id])
    render(json: { error: 'departamento não encontrado' }, status: :not_found) if @department.nil?
  end

  def set_source
    @source = @department.knowledge_sources.find_by(id: params[:id])
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
