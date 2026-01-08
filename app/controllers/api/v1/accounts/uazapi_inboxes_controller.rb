# frozen_string_literal: true

class Api::V1::Accounts::UazapiInboxesController < Api::V1::Accounts::BaseController
  before_action :check_authorization

  def create
    # Validate phone number format (exactly 13 digits, all numeric)
    phone_number = permitted_params[:phone_number].to_s.gsub(/\D/, '')
    unless phone_number.length == 13 && phone_number.match?(/^\d{13}$/)
      return render json: {
        error: I18n.t('errors.uazapi.phone_number_invalid')
      }, status: :unprocessable_entity
    end

    result = Whatsapp::UazapiConnectionService.new(
      inbox_name: permitted_params[:name],
      phone_number: phone_number,
      account: Current.account
    ).perform

    if result[:success]
      render json: {
        inbox: inbox_json(result[:inbox]),
        qr_code: result[:qr_code],
        status: result[:status],
        connection_data: result[:connection_data],
        webhook_url: result[:webhook_url]
      }, status: :ok
    else
      render json: { error: result[:error] }, status: :unprocessable_entity
    end
  rescue StandardError => e
    Rails.logger.error "[UAZAPI] Create inbox error: #{e.message}"
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def permitted_params
    params.permit(:name, :phone_number)
  end

  def check_authorization
    authorize :inbox, :create?
  end

  def inbox_json(inbox)
    channel = inbox.channel
    channel.reload if channel.persisted? # Ensure we have the latest webhook_url
    {
      id: inbox.id,
      name: inbox.name,
      channel_id: channel.id,
      channel_type: inbox.channel_type,
      phone_number: channel.additional_attributes&.dig('phone_number'),
      identifier: channel.identifier,
      webhook_url: channel.webhook_url,
      is_uazapi: true
    }
  end
end


