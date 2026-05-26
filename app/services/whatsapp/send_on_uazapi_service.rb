class Whatsapp::SendOnUazapiService < Base::SendOnChannelService
  private

  def channel_class
    Channel::Api
  end

  def perform_reply
    uazapi_service = Whatsapp::Providers::UazapiService.new(whatsapp_channel: channel)
    phone_number = conversation.contact_inbox.source_id
    uazapi_service.send_message(phone_number, message)
  end

  def validate_target_channel
    raise 'Invalid channel service' unless inbox.channel.is_a?(Channel::Api)
    raise 'Not a UazAPI channel' unless channel.additional_attributes&.dig('uazapi_instance_token').present?
  end
end