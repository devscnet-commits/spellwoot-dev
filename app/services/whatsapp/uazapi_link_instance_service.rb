# frozen_string_literal: true

class Whatsapp::UazapiLinkInstanceService
  def initialize(inbox_name:, provider_instance:, account:)
    @inbox_name = inbox_name
    @provider_instance = provider_instance
    @account = account
  end

  def perform
    instance_token = @provider_instance.instance_token
    unless instance_token.present?
      return { success: false, error: 'Token da instância não encontrado. Sincronize as instâncias novamente.' }
    end

    channel = Channel::Api.create!(
      account_id: @account.id,
      additional_attributes: {
        'uazapi_instance_token'  => instance_token,
        'uazapi_instance_id'     => @provider_instance.instance_id,
        'uazapi_instance_name'   => @provider_instance.instance_name,
        'phone_number'           => @provider_instance.phone_number,
        'provider_instance_id'   => @provider_instance.id
      }
    )

    inbox = @account.inboxes.create!(name: @inbox_name, channel: channel)

    webhook_url = configure_chatwoot_integration(inbox, instance_token)
    channel.update!(webhook_url: webhook_url) if webhook_url.present?

    { success: true, inbox: inbox, channel: channel.reload, webhook_url: webhook_url }
  rescue StandardError => e
    Rails.logger.error "[UAZAPI] Link instance error: #{e.message}"
    { success: false, error: e.message }
  end

  private

  def configure_chatwoot_integration(inbox, instance_token)
    return nil unless Current.user.present?

    access_token = Current.user.access_token&.token
    return nil unless access_token.present?

    creds = Whatsapp::Providers::UazapiService.credentials_for(@account.id)
    chatwoot_url = creds[:webhook_base_url] || ENV.fetch('FRONTEND_URL', nil)
    return nil unless chatwoot_url.present?

    config = {
      enabled: true,
      url: chatwoot_url,
      access_token: access_token,
      account_id: @account.id,
      inbox_id: inbox.id,
      ignore_groups: false,
      sign_messages: true,
      create_new_conversation: true
    }

    result = Whatsapp::Providers::UazapiService.configure_chatwoot_integration(instance_token, config, account_id: @account.id)
    result&.dig('chatwoot_inbox_webhook_url')
  end
end
