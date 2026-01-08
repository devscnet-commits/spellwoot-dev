# frozen_string_literal: true

class Webhooks::UazapiController < ActionController::API
  def process_payload
    identifier = params[:identifier]
    Rails.logger.info "[UAZAPI] Received webhook for identifier=#{identifier}"
    Rails.logger.info "[UAZAPI] Payload keys: #{params.keys.join(', ')}"

    channel = Channel::Api.find_by(identifier: identifier)
    unless channel
      Rails.logger.error "[UAZAPI] Channel::Api not found for identifier=#{identifier}"
      return render json: { error: 'Channel not found' }, status: :not_found
    end

    Rails.logger.info "[UAZAPI] Found channel: channel_id=#{channel.id}, inbox_id=#{channel.inbox.id}"

    # Process the webhook payload asynchronously
    Webhooks::UazapiEventsJob.perform_later(params.to_unsafe_hash.merge(channel_id: channel.id))
    head :ok
  rescue StandardError => e
    Rails.logger.error "[UAZAPI] Webhook processing error: #{e.message}"
    Rails.logger.error "[UAZAPI] #{e.backtrace.join("\n")}"
    render json: { error: 'Internal server error' }, status: :internal_server_error
  end
end


