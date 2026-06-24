# CRUD for the account's shared knowledge library, with chunking + embedding ingestion (RAG).
# Account-level: a single library every agent draws from, ingested once. Reuses the embedding
# service technically; if unavailable, chunks are stored without vectors (retrieval falls back to text).
class Api::V1::Accounts::AiKnowledgeSourcesController < Api::V1::Accounts::BaseController
  before_action :set_source, only: %i[update destroy]

  def index
    render json: scope.order(:id).map { |source| serialize(source) }
  end

  def create
    source = scope.new(create_attributes.merge(account_id: Current.account.id))
    return render(json: { errors: source.errors.full_messages }, status: :unprocessable_entity) unless source.save

    ingest(source)
    render json: serialize(source), status: :created
  rescue UploadError => e
    render(json: { errors: [e.message] }, status: :unprocessable_entity)
  end

  def update
    before = [@source.raw, @source.price]
    return render(json: { errors: @source.errors.full_messages }, status: :unprocessable_entity) unless @source.update(source_params)

    ingest(@source) if before != [@source.raw, @source.price]
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
    params.require(:ai_knowledge_source).permit(:kind, :title, :raw, :status, :price)
  end

  # A file upload (TXT/CSV) becomes a "documento" source whose text is the file content;
  # the existing chunk/embedding ingestion then indexes it. PDF/site stay roadmap.
  UploadError = Class.new(StandardError)
  ALLOWED_UPLOAD_EXTENSIONS = %w[.txt .csv].freeze
  MAX_UPLOAD_BYTES = 2.megabytes

  def create_attributes
    file = params[:file]
    return source_params unless file.respond_to?(:read)

    raise UploadError, 'Arquivo acima de 2 MB.' if file.size > MAX_UPLOAD_BYTES
    ext = File.extname(file.original_filename.to_s).downcase
    raise UploadError, 'Formato não suportado. Use TXT ou CSV.' unless ALLOWED_UPLOAD_EXTENSIONS.include?(ext)

    { kind: 'documento', title: File.basename(file.original_filename.to_s, ext),
      raw: file.read.to_s.encode('UTF-8', invalid: :replace, undef: :replace), status: 'active' }
  end

  def ingest(source)
    source.chunks.delete_all
    pieces = source.raw.to_s.split(/\n\s*\n/).map(&:strip).reject(&:blank?)
    pieces = [source.raw.to_s.strip] if pieces.empty? && source.raw.present?
    # Price lives in its own column (clean UI), but must be retrievable so the AI can answer
    # "quanto custa?" — index it as a chunk tied to the source title.
    pieces << "#{source.title} — Preço: #{source.price}".strip if source.price.present?
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
