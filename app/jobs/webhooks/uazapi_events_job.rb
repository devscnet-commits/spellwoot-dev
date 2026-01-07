# frozen_string_literal: true

class Webhooks::UazapiEventsJob < ApplicationJob
  queue_as :default

  def perform(params)
    return unless params[:phone_number]

    channel = find_channel(params[:phone_number])
    return unless channel

    process_event(channel, params)
  end

  private

  def find_channel(phone_number)
    Channel::Whatsapp.find_by(phone_number: phone_number, provider: 'uazapi')
  end

  def process_event(channel, params)
    event_type = determine_event_type(params)

    case event_type
    when :message
      process_message_event(channel, params)
    when :message_update
      process_message_update_event(channel, params)
    when :connection
      process_connection_event(channel, params)
    end
  end

  def determine_event_type(params)
    return :connection if params[:event] == 'connection' || params.dig('data', 'event') == 'connection'
    return :message_update if params[:event] == 'messages_update' || params.dig('data', 'event') == 'messages_update'

    :message
  end

  def process_message_event(channel, params)
    # Extract message data from UazAPI webhook format
    message_data = extract_message_data(params)
    return if message_data.blank?

    # Skip messages sent by the API itself
    return if message_data[:from_me] && message_data[:was_sent_by_api]

    Whatsapp::IncomingMessageUazapiService.new(
      inbox: channel.inbox,
      params: message_data
    ).perform
  rescue StandardError => e
    Rails.logger.error "[UAZAPI] Message processing error: #{e.message}"
  end

  def process_message_update_event(channel, params)
    # Handle message status updates (delivered, read, etc.)
    message_id = params.dig('data', 'messageid') || params['messageid']
    status = params.dig('data', 'status') || params['status']

    return if message_id.blank? || status.blank?

    message = channel.inbox.messages.find_by(source_id: message_id)
    return unless message

    update_message_status(message, status)
  rescue StandardError => e
    Rails.logger.error "[UAZAPI] Message update error: #{e.message}"
  end

  def process_connection_event(channel, params)
    status = params.dig('data', 'status') || params['status']
    Rails.logger.info "[UAZAPI] Connection status changed to: #{status} for channel #{channel.id}"

    # Could emit an event or update channel status here if needed
  end

  def extract_message_data(params)
    data = params['data'] || params

    {
      message_id: data['messageid'] || data['id'],
      phone: data['sender'] || data['phone'] || data['from'],
      text: data['text'] || data.dig('message', 'text') || data.dig('message', 'conversation'),
      message_type: data['messageType'] || data['type'] || 'text',
      timestamp: data['messageTimestamp'] || Time.current.to_i,
      from_me: data['fromMe'] || false,
      was_sent_by_api: data['wasSentByApi'] || false,
      is_group: data['isGroup'] || false,
      sender_name: data['senderName'] || data.dig('pushName'),
      quoted_message_id: data['quoted'],
      file_url: data['fileURL'],
      media_type: determine_media_type(data)
    }
  end

  def determine_media_type(data)
    message_type = data['messageType'] || data['type']
    case message_type
    when 'image', 'imageMessage' then 'image'
    when 'video', 'videoMessage' then 'video'
    when 'audio', 'audioMessage', 'ptt' then 'audio'
    when 'document', 'documentMessage' then 'document'
    when 'sticker', 'stickerMessage' then 'sticker'
    else nil
    end
  end

  def update_message_status(message, status)
    new_status = case status.to_s.downcase
                 when 'sent', 'server' then :sent
                 when 'delivered', 'delivery' then :delivered
                 when 'read' then :read
                 when 'failed', 'error' then :failed
                 else return
                 end

    message.update!(status: new_status)
  end
end

