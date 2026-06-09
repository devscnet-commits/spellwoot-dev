# frozen_string_literal: true

class Api::V1::Accounts::ProviderInstancesController < Api::V1::Accounts::BaseController
  before_action :check_authorization

  def index
    instances = ProviderInstance.where(
      account_id: Current.account.id,
      provider: params[:provider]
    ).order(:instance_name)
    render json: instances.map { |i| instance_json(i) }
  end

  private

  def check_authorization
    authorize(IntegrationSetting)
  end

  def instance_json(inst)
    {
      id:            inst.id,
      provider:      inst.provider,
      instance_id:   inst.instance_id,
      instance_name: inst.instance_name,
      phone_number:  inst.phone_number,
      status:        inst.status,
      has_token:     inst.instance_token.present?,
      updated_at:    inst.updated_at
    }
  end
end
