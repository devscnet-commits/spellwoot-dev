# frozen_string_literal: true

class Uazapi::IncomingMessageService
  pattr_initialize [:inbox!, :params!]

  # Webhook events that are not user messages: connection/presence/instance updates carry
  # the instance's own number and were creating a daily ghost contact + empty conversation.
  NON_MESSAGE_EVENTS = %w[connection presence qrcode status instance chats contacts history sync token].freeze

  def perform
    Rails.logger.info "[UAZAPI] Processing incoming message for inbox_id=#{inbox.id}"
    Rails.logger.info "[UAZAPI] Params keys: #{params.keys.join(', ')}"

    # UazAPI sends messages in different formats depending on the webhook configuration
    # The payload structure may vary, so we need to handle different formats
    if non_message_event?
      Rails.logger.info "[UAZAPI] Skipping non-message event type=#{event_type}"
      return
    end

    message_data = extract_message_data(params)

    return unless message_data.present?

    # A genuine message always has text or media; connection/status payloads have neither —
    # without this, they materialize a ghost contact and an empty conversation.
    if message_data[:body].blank? && message_data[:media_url].blank?
      Rails.logger.info "[UAZAPI] Skipping event without message content from=#{message_data[:from]}"
      return
    end

    Rails.logger.info "[UAZAPI] Message data extracted: type=#{message_data[:type]}, from=#{message_data[:from]}"

    # Skip if message is from the bot itself
    return if message_data[:from_me] == true

    # Check for duplicate messages
    if message_data[:message_id].present?
      existing_message = Message.find_by(source_id: message_data[:message_id].to_s, inbox_id: inbox.id)
      if existing_message
        Rails.logger.info "[UAZAPI] Message already exists, skipping: " \
                           "message_id=#{message_data[:message_id]}, existing_message_id=#{existing_message.id}"
        return
      end
    end

    set_contact(message_data)
    return unless @contact

    ActiveRecord::Base.transaction do
      set_conversation
      create_message(message_data)
    end
  rescue StandardError => e
    Rails.logger.error "[UAZAPI] Error processing incoming message: #{e.message}"
    Rails.logger.error "[UAZAPI] #{e.backtrace.join("\n")}"
  end

  private

  def event_type
    (params[:EventType] || params[:eventType] || params[:event]).to_s.downcase
  end

  def non_message_event?
    type = event_type
    return false if type.blank?

    NON_MESSAGE_EVENTS.any? { |non_message| type.include?(non_message) }
  end

  def extract_message_data(params)
    # UazAPI webhook format can vary, try to extract common fields
    # Common structure: { "message": { "from": "...", "body": "...", ... } }
    # Or direct fields: { "from": "...", "body": "...", ... }

    message = params[:message] || params
    return nil unless message.present?

    {
      from: message[:from] || message['from'] || message[:number] || message['number'],
      body: message[:body] || message['body'] || message[:text] || message['text'] || message[:message] || message['message'],
      message_id: message[:id] || message['id'] || message[:messageId] || message['messageId'],
      timestamp: message[:timestamp] || message['timestamp'] || Time.current.to_i,
      type: message[:type] || message['type'] || 'text',
      from_me: message[:fromMe] || message['fromMe'] || message[:from_me] || message['from_me'] || false,
      media_url: message[:mediaUrl] || message['mediaUrl'] || message[:media_url] || message['media_url'],
      caption: message[:caption] || message['caption']
    }
  end

  def set_contact(message_data)
    phone_number = message_data[:from]
    return unless phone_number.present?

    Rails.logger.info "[UAZAPI] Setting contact for phone_number=#{phone_number}"

    formatted_phone = format_phone_number(phone_number)
    # Remove + for source_id (similar to WhatsApp)
    source_id = formatted_phone.delete('+')

    contact_inbox = ::ContactInboxWithContactBuilder.new(
      source_id: source_id,
      inbox: inbox,
      contact_attributes: {
        name: formatted_phone,
        phone_number: formatted_phone
      }
    ).perform

    @contact_inbox = contact_inbox
    @contact = contact_inbox.contact

    Rails.logger.info "[UAZAPI] Contact set: contact_id=#{@contact.id}, contact_inbox_id=#{@contact_inbox.id}"
  end

  def set_conversation
    Rails.logger.info "[UAZAPI] Setting conversation for contact_id=#{@contact.id}"

    # if lock to single conversation is disabled, we will create a new conversation if previous conversation is resolved,
    # unless the last resolved conversation is still inside the inbox reopen window (in hours).
    @conversation = if inbox.lock_to_single_conversation
                      @contact_inbox.conversations.last
                    else
                      @contact_inbox.conversations.where.not(status: :resolved).last ||
                        reopenable_conversation_within_window
                    end

    if @conversation.blank?
      Rails.logger.info "[UAZAPI] Creating new conversation"
      @conversation = ::Conversation.create!(
        account_id: inbox.account_id,
        inbox_id: inbox.id,
        contact_id: @contact.id,
        contact_inbox_id: @contact_inbox.id,
        status: :open
      )
    else
      Rails.logger.info "[UAZAPI] Found existing conversation: conversation_id=#{@conversation.id}"
    end
  end

  # Returns the last resolved conversation if it was resolved within the inbox reopen window (hours),
  # so a new incoming message reopens it (via Message#reopen_conversation) instead of creating a new one.
  def reopenable_conversation_within_window
    hours = inbox.reopen_window_hours.to_i
    if hours <= 0
      Rails.logger.info "[UAZAPI] reopen-window off reopen_window_hours=#{inbox.reopen_window_hours.inspect}"
      return nil
    end

    last_conversation = @contact_inbox.conversations.last
    unless last_conversation&.resolved?
      Rails.logger.info "[UAZAPI] reopen-window no resolved conversation to reopen (last=#{last_conversation&.id} status=#{last_conversation&.status})"
      return nil
    end

    reference = last_conversation.last_activity_at || last_conversation.updated_at
    cutoff = hours.hours.ago
    within = reference.present? && reference >= cutoff
    Rails.logger.info(
      "[UAZAPI] reopen-window conv=#{last_conversation.id} hours=#{hours} " \
      "reference=#{reference} cutoff=#{cutoff} within=#{within}"
    )
    last_conversation if within
  end

  def create_message(message_data)
    Rails.logger.info "[UAZAPI] Creating message in conversation_id=#{@conversation.id}"

    message_params = {
      account_id: inbox.account_id,
      inbox_id: inbox.id,
      conversation_id: @conversation.id,
      sender: @contact,
      content: message_data[:body],
      message_type: :incoming,
      source_id: message_data[:message_id].present? ? message_data[:message_id].to_s : nil,
      in_reply_to_external_id: message_data[:in_reply_to]
    }.compact

    message = @conversation.messages.build(message_params)

    # Handle attachments if present
    if message_data[:media_url].present?
      Rails.logger.info "[UAZAPI] Processing attachment: media_url=#{message_data[:media_url]}"
      attach_media_file(message, message_data)
    end

    message.save!
    Rails.logger.info "[UAZAPI] Message created successfully: message_id=#{message.id}"
    message
  end

  def format_phone_number(phone_number)
    # Remove any non-numeric characters and ensure it starts with +
    phone = phone_number.to_s.gsub(/\D/, '')
    phone.start_with?('+') ? phone : "+#{phone}"
  end

  def determine_file_type(type)
    case type.to_s.downcase
    when 'image' then 'image'
    when 'video' then 'video'
    when 'audio', 'ptt' then 'audio'
    when 'document' then 'file'
    else 'file'
    end
  end

  def attach_media_file(message, message_data)
    media_url = message_data[:media_url]
    file_type = determine_file_type(message_data[:type])

    Rails.logger.info "[UAZAPI] Downloading attachment from: #{media_url}"

    attachment_file = download_media_file(media_url)
    unless attachment_file
      Rails.logger.warn "[UAZAPI] Failed to download attachment from: #{media_url}"
      # Fallback: create attachment with external_url only
      message.attachments.build(
        account_id: inbox.account_id,
        file_type: file_type,
        external_url: media_url
      )
      return
    end

    message.content ||= message_data[:caption]

    message.attachments.build(
      account_id: inbox.account_id,
      file_type: file_type,
      file: {
        io: attachment_file,
        filename: attachment_file.original_filename || File.basename(media_url),
        content_type: attachment_file.content_type || 'application/octet-stream'
      }
    )

    Rails.logger.info "[UAZAPI] Attachment prepared for message"
  rescue StandardError => e
    Rails.logger.error "[UAZAPI] Error downloading attachment: #{e.message}"
    Rails.logger.error "[UAZAPI] #{e.backtrace.join("\n")}"
    # Fallback: create attachment with external_url only
    message.attachments.build(
      account_id: inbox.account_id,
      file_type: determine_file_type(message_data[:type]),
      external_url: media_url
    )
  end

  def download_media_file(media_url)
    instance_token = inbox.channel&.additional_attributes&.dig('uazapi_instance_token')
    headers = instance_token.present? ? { 'token' => instance_token } : {}
    Down.download(media_url, headers: headers, open_timeout: 15, read_timeout: 30)
  rescue StandardError => e
    Rails.logger.error "[UAZAPI] Error downloading file from #{media_url}: #{e.message}"
    nil
  end
end

