# CRUD for Shadows (quality observers). Account-scoped. Inbox links are synced from inbox_ids.
class Api::V1::Accounts::AiShadowsController < Api::V1::Accounts::BaseController
  before_action :set_shadow, only: %i[update destroy]

  def index
    render json: scope.includes(:shadow_inboxes).order(:name).map { |shadow| serialize(shadow) }
  end

  def create
    shadow = scope.new(shadow_params.merge(account_id: Current.account.id, **jsonb_params))
    return render(json: { errors: shadow.errors.full_messages }, status: :unprocessable_entity) unless shadow.save

    sync_inboxes(shadow)
    render json: serialize(shadow), status: :created
  end

  def update
    @shadow.assign_attributes(shadow_params.merge(jsonb_params))
    return render(json: { errors: @shadow.errors.full_messages }, status: :unprocessable_entity) unless @shadow.save

    sync_inboxes(@shadow)
    render json: serialize(@shadow)
  end

  def destroy
    @shadow.destroy!
    head :no_content
  end

  private

  def scope
    ::Ai::Shadow.where(account_id: Current.account.id)
  end

  def set_shadow
    @shadow = scope.find_by(id: params[:id])
    render(json: { error: 'não encontrado' }, status: :not_found) if @shadow.nil?
  end

  def shadow_params
    params.require(:ai_shadow).permit(:name, :instructions, :status)
  end

  def jsonb_params
    source = params[:ai_shadow] || {}
    out = {}
    out[:scope] = hashify(source[:scope]) if source.key?(:scope)
    out[:data_signals] = hashify(source[:data_signals]) if source.key?(:data_signals)
    out
  end

  def hashify(value)
    value.respond_to?(:permit!) ? value.permit!.to_h : (value || {})
  end

  def sync_inboxes(shadow)
    return unless params[:ai_shadow]&.key?(:inbox_ids)

    ids = Array(params[:ai_shadow][:inbox_ids]).map(&:to_i).uniq
    shadow.shadow_inboxes.delete_all
    ids.each { |inbox_id| shadow.shadow_inboxes.create(inbox_id: inbox_id) }
  end

  def serialize(shadow)
    shadow.as_json.merge('inbox_ids' => shadow.shadow_inboxes.map(&:inbox_id))
  end
end
