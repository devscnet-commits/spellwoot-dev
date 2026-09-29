# A IA nunca responde grupo. Até aqui toda instância UazAPI era configurada com ignore_groups: false, então a
# UazAPI empurrava mensagem de grupo para a inbox. Liga ignore_groups nas instâncias existentes, sem o cliente
# precisar reconectar nada.
#
# O PUT /chatwoot/config exige a configuração inteira, então lê a atual (GET) e devolve os MESMOS valores —
# token, inbox, create_new_conversation, sign_messages — trocando só ignore_groups. Instância com a integração
# desligada ou já ignorando grupos fica como está.
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
    token = channel.additional_attributes['uazapi_instance_token']
    current = inbox && Whatsapp::Providers::UazapiService.get_chatwoot_config(token, account_id: inbox.account_id)
    return unless current.is_a?(Hash) && current['chatwoot_enabled'] && !current['chatwoot_ignore_groups']

    Whatsapp::Providers::UazapiService.configure_chatwoot_integration(token, same_config(current), account_id: inbox.account_id)
  end

  def same_config(current)
    { enabled: true, url: current['chatwoot_url'], access_token: current['chatwoot_access_token'],
      account_id: current['chatwoot_account_id'], inbox_id: current['chatwoot_inbox_id'], ignore_groups: true,
      sign_messages: current['chatwoot_sign_messages'], create_new_conversation: current['chatwoot_create_new_conversation'] }
  end
end
