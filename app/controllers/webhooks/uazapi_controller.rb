# frozen_string_literal: true

class Webhooks::UazapiController < ActionController::API
  def verify
    # UazAPI may send verification requests
    render json: { status: 'ok' }, status: :ok
  end

  def process_payload
    Rails.logger.info "[UAZAPI] Webhook received for phone: #{params[:phone_number]}"

    Webhooks::UazapiEventsJob.perform_later(params.to_unsafe_hash)
    head :ok
  rescue StandardError => e
    Rails.logger.error "[UAZAPI] Webhook processing error: #{e.message}"
    head :ok # Return OK to prevent retries
  end

  private

  def find_channel
    Channel::Whatsapp.find_by(phone_number: params[:phone_number], provider: 'uazapi')
  end
end


