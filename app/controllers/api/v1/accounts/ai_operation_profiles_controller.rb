# CRUD for operation profiles (Econômico/Balanceado/Premium). Provider-agnostic: each points to
# a supervisor provider + model; workers/budget live in jsonb.
class Api::V1::Accounts::AiOperationProfilesController < Api::V1::Accounts::BaseController
  before_action :set_profile, only: %i[update destroy]

  def index
    render json: ::Ai::OperationProfile.where(account_id: Current.account.id).order(:name)
  end

  def create
    profile = ::Ai::OperationProfile.new(profile_params.merge(account_id: Current.account.id))
    profile.assign_attributes(jsonb_params)
    save_and_render(profile, :created)
  end

  def update
    @profile.assign_attributes(profile_params.merge(jsonb_params))
    save_and_render(@profile, :ok)
  end

  def destroy
    @profile.destroy!
    head :no_content
  end

  private

  def set_profile
    @profile = ::Ai::OperationProfile.find_by(id: params[:id], account_id: Current.account.id)
    render(json: { error: 'não encontrado' }, status: :not_found) if @profile.nil?
  end

  def profile_params
    params.require(:ai_operation_profile).permit(:name, :supervisor_provider, :supervisor_model)
  end

  def jsonb_params
    source = params[:ai_operation_profile] || {}
    out = {}
    out[:budget] = hashify(source[:budget]) if source[:budget]
    out[:worker_overrides] = hashify(source[:worker_overrides]) if source[:worker_overrides]
    out
  end

  def hashify(value)
    value.respond_to?(:permit!) ? value.permit!.to_h : value
  end

  def save_and_render(profile, ok_status)
    if profile.save
      render json: profile, status: ok_status
    else
      render json: { errors: profile.errors.full_messages }, status: :unprocessable_entity
    end
  end
end
