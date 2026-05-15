class Whatsapp::WebhookTeardownService
  def initialize(channel)
    @channel = channel
  end

  def perform
    if uazapi_api_channel?
      teardown_uazapi_api_channel
    elsif should_teardown_webhook?
      teardown_webhook
    end
  rescue StandardError => e
    handle_webhook_teardown_error(e)
  end

  private

  def uazapi_api_channel?
    @channel.is_a?(Channel::Api) && @channel.additional_attributes&.dig('uazapi_instance_token').present?
  end

  def should_teardown_webhook?
    whatsapp_cloud_provider? && embedded_signup_source? && webhook_config_present?
  end

  def whatsapp_cloud_provider?
    @channel.is_a?(Channel::Whatsapp) && @channel.provider == 'whatsapp_cloud'
  end

  def embedded_signup_source?
    @channel.is_a?(Channel::Whatsapp) && @channel.provider_config['source'] == 'embedded_signup'
  end

  def webhook_config_present?
    @channel.is_a?(Channel::Whatsapp) &&
      @channel.provider_config['business_account_id'].present? &&
      @channel.provider_config['api_key'].present?
  end

  def teardown_webhook
    waba_id = @channel.provider_config['business_account_id']
    access_token = @channel.provider_config['api_key']
    api_client = Whatsapp::FacebookApiClient.new(access_token)

    api_client.unsubscribe_waba_webhook(waba_id)
    Rails.logger.info "[WHATSAPP] Webhook unsubscribed successfully for channel #{@channel.id}"
  end

  def teardown_uazapi_api_channel
    Rails.logger.info "[UAZAPI] Tearing down UazAPI API channel: channel_id=#{@channel.id}"
    
    instance_token = @channel.additional_attributes&.dig('uazapi_instance_token')
    unless instance_token.present?
      Rails.logger.warn "[UAZAPI] Instance token not found for channel_id=#{@channel.id}"
      return
    end

    # Step 1: Disable Chatwoot integration
    Rails.logger.info "[UAZAPI] Disabling Chatwoot integration for channel_id=#{@channel.id}"
    disable_chatwoot_integration(instance_token)

    # Step 2: Delete instance
    Rails.logger.info "[UAZAPI] Deleting UazAPI instance for channel_id=#{@channel.id}"
    delete_uazapi_instance(instance_token)
  end

  def disable_chatwoot_integration(instance_token)
    base_url = Whatsapp::Providers::UazapiService.base_url
    headers = {
      'Content-Type' => 'application/json',
      'token' => instance_token
    }

    config = {
      enabled: false
    }

    begin
      response = HTTParty.put(
        "#{base_url}/chatwoot/config",
        headers: headers,
        body: config.to_json
      )

      if response.success?
        Rails.logger.info "[UAZAPI] Chatwoot integration disabled successfully"
      else
        Rails.logger.warn "[UAZAPI] Failed to disable Chatwoot integration: #{response.body}"
      end
    rescue StandardError => e
      Rails.logger.error "[UAZAPI] Error disabling Chatwoot integration: #{e.message}"
      Rails.logger.error "[UAZAPI] #{e.backtrace.join("\n")}"
    end
  end

  def delete_uazapi_instance(instance_token)
    base_url = Whatsapp::Providers::UazapiService.base_url
    headers = {
      'Content-Type' => 'application/json',
      'token' => instance_token
    }

    begin
      response = HTTParty.delete(
        "#{base_url}/instance",
        headers: headers
      )

      if response.success?
        Rails.logger.info "[UAZAPI] Instance deleted successfully"
      else
        Rails.logger.warn "[UAZAPI] Failed to delete instance: #{response.body}"
      end
    rescue StandardError => e
      Rails.logger.error "[UAZAPI] Error deleting instance: #{e.message}"
      Rails.logger.error "[UAZAPI] #{e.backtrace.join("\n")}"
    end
  end

  def handle_webhook_teardown_error(error)
    Rails.logger.error "[WHATSAPP] Webhook teardown failed: #{error.message}"
    # Don't raise the error to prevent channel deletion from failing
    # Failed webhook teardown shouldn't block deletion
  end
end
