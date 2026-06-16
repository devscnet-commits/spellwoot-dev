class Whatsapp::SendOnUazapiService < Base::SendOnChannelService
  private

  def channel_class
    Channel::Api
  end

  def perform_reply
    instance_token = channel.additional_attributes&.dig('uazapi_instance_token')

    channel_wrapper = OpenStruct.new(
      provider_config: { 'uazapi_instance_token' => instance_token }
    )

    uazapi_service = Whatsapp::Providers::UazapiService.new(whatsapp_channel: channel_wrapper)
    uazapi_service.send_message(recipient_identifier, message)
  end

  # The recipient must be the WhatsApp phone number. contact_inbox.source_id holds the number
  # for contacts created through our webhook, but contacts created via other paths (e.g. the
  # native UazAPI↔Chatwoot bridge) get a UUID source_id — sending to that makes UazAPI treat
  # it as a group id and fail ("failed to get group members"). Prefer the contact's phone
  # number, which is the canonical WhatsApp number, and fall back to source_id.
  def recipient_identifier
    conversation.contact&.phone_number.presence || conversation.contact_inbox.source_id
  end

  def validate_target_channel
    raise 'Invalid channel service' unless inbox.channel.is_a?(Channel::Api)
    raise 'Not a UazAPI channel' unless channel.additional_attributes&.dig('uazapi_instance_token').present?
  end
end
