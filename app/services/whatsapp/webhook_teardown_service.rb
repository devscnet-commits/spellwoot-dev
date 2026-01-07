class Whatsapp::WebhookTeardownService
  def initialize(channel)
    @channel = channel
  end

  def perform
    if uazapi_provider?
      teardown_uazapi_instance
    elsif should_teardown_webhook?
      teardown_webhook
    end
  rescue StandardError => e
    handle_webhook_teardown_error(e)
  end

  private

  def uazapi_provider?
    @channel.provider == 'uazapi'
  end

  def should_teardown_webhook?
    whatsapp_cloud_provider? && embedded_signup_source? && webhook_config_present?
  end

  def whatsapp_cloud_provider?
    @channel.provider == 'whatsapp_cloud'
  end

  def embedded_signup_source?
    @channel.provider_config['source'] == 'embedded_signup'
  end

  def webhook_config_present?
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

  def teardown_uazapi_instance
    Rails.logger.info "[UAZAPI] Deleting UazAPI instance for channel #{@channel.id}"
    provider_service = @channel.provider_service
    result = provider_service.delete_instance
    if result
      Rails.logger.info "[UAZAPI] Instance deleted successfully for channel #{@channel.id}"
    else
      Rails.logger.warn "[UAZAPI] Failed to delete instance for channel #{@channel.id}"
    end
  end

  def handle_webhook_teardown_error(error)
    Rails.logger.error "[WHATSAPP] Webhook teardown failed: #{error.message}"
    # Don't raise the error to prevent channel deletion from failing
    # Failed webhook teardown shouldn't block deletion
  end
end
