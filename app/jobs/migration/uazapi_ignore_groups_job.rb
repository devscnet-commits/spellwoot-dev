# A IA nunca responde grupo. Até aqui toda instância UazAPI era configurada com ignore_groups: false, então a
# UazAPI empurrava mensagem de grupo para a inbox. Reaplica a integração com ignore_groups: true em todas as
# inboxes UazAPI existentes, sem o cliente precisar reconectar nada.
class Migration::UazapiIgnoreGroupsJob < ApplicationJob
  queue_as :low

  def perform
    Channel::Api.where("additional_attributes ->> 'uazapi_instance_token' IS NOT NULL").find_each do |channel|
      reconfigure(channel)
    end
  end

  private

  def reconfigure(channel)
    inbox = channel.inbox
    config = inbox && chatwoot_config(inbox)
    return if config.nil?

    result = Whatsapp::Providers::UazapiService.configure_chatwoot_integration(
      channel.additional_attributes['uazapi_instance_token'], config, account_id: inbox.account_id
    )
    webhook_url = result&.dig('chatwoot_inbox_webhook_url')
    channel.update!(webhook_url: webhook_url) if webhook_url.present?
  end

  def chatwoot_config(inbox)
    access_token = inbox.account.administrators.filter_map { |user| user.access_token&.token }.first
    url = Whatsapp::Providers::UazapiService.credentials_for(inbox.account_id)[:webhook_base_url] || ENV.fetch('FRONTEND_URL', nil)
    return if access_token.blank? || url.blank?

    { enabled: true, url: url, access_token: access_token, account_id: inbox.account_id, inbox_id: inbox.id,
      ignore_groups: true, sign_messages: true, create_new_conversation: true }
  end
end
