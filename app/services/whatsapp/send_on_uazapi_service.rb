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
    source_id = conversation.contact_inbox.source_id.to_s
    # Groups/JIDs contain '@' (e.g. "1203...@g.us") and must be addressed exactly as-is.
    # Individuals use the contact phone number (covers UUID source_ids created by the
    # native bridge), falling back to source_id.
    return source_id if source_id.include?('@')

    conversation.contact&.phone_number.presence || source_id
  end

  def validate_target_channel
    raise 'Invalid channel service' unless inbox.channel.is_a?(Channel::Api)
    raise 'Not a UazAPI channel' unless channel.additional_attributes&.dig('uazapi_instance_token').present?
  end
end
