# CRUD for external integration connectors (consumed by Tools with implementation_type=integration).
# Account-scoped. The `test` action fires a real call through Ai::IntegrationConnector so the user
# can validate the connection from the UI before using it.
class Api::V1::Accounts::AiIntegrationLinksController < Api::V1::Accounts::BaseController
  before_action :set_link, only: %i[update destroy test]

  def index
    render json: scope.order(:name)
  end

  def create
    link = scope.new(link_params.merge(jsonb_params))
    save_and_render(link, :created)
  end

  def update
    @link.assign_attributes(link_params.merge(jsonb_params))
    save_and_render(@link, :ok)
  end

  def destroy
    @link.destroy!
    head :no_content
  end

  # Fires the configured request once and returns a clear success/error read-out for the UI.
  def test
    input = params[:sample_input].respond_to?(:permit!) ? params[:sample_input].permit!.to_h : {}
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    begin
      result = ::Ai::IntegrationConnector.call(@link, input: input)
      render json: { ok: true, status: result['status'], latency_ms: elapsed_ms(started), body: result['body'] }
    rescue StandardError => e
      render json: { ok: false, latency_ms: elapsed_ms(started), error: e.message }
    end
  end

  private

  def scope
    ::Ai::IntegrationLink.where(account_id: Current.account.id)
  end

  def set_link
    @link = scope.find_by(id: params[:id])
    render(json: { error: 'não encontrada' }, status: :not_found) if @link.nil?
  end

  def link_params
    params.require(:ai_integration_link).permit(
      :name, :kind, :endpoint, :http_method, :status, :retry_count, :timeout_seconds
    ).merge(account_id: Current.account.id)
  end

  def jsonb_params
    source = params[:ai_integration_link] || {}
    out = {}
    out[:auth] = hashify(source[:auth]) if source.key?(:auth)
    out[:headers] = hashify(source[:headers]) if source.key?(:headers)
    out[:payload_template] = hashify(source[:payload_template]) if source.key?(:payload_template)
    out
  end

  def hashify(value)
    value.respond_to?(:permit!) ? value.permit!.to_h : (value || {})
  end

  def elapsed_ms(started)
    ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
  end

  def save_and_render(link, ok_status)
    if link.save
      render json: link, status: ok_status
    else
      render json: { errors: link.errors.full_messages }, status: :unprocessable_entity
    end
  end
end
