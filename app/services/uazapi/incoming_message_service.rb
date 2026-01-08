# frozen_string_literal: true

class Uazapi::IncomingMessageService
  pattr_initialize [:inbox!, :params!]

  def perform
    Rails.logger.info "[UAZAPI] Processing incoming message for inbox_id=#{inbox.id}"
    Rails.logger.info "[UAZAPI] Params keys: #{params.keys.join(', ')}"

    # UazAPI sends messages in different formats depending on the webhook configuration
    # The payload structure may vary, so we need to handle different formats
    message_data = extract_message_data(params)

    return unless message_data.present?

    Rails.logger.info "[UAZAPI] Message data extracted: type=#{message_data[:type]}, from=#{message_data[:from]}"

    # Skip if message is from the bot itself
    return if message_data[:from_me] == true

    # Check for duplicate messages
    if message_data[:message_id].present?
      existing_message = Message.find_by(source_id: message_data[:message_id].to_s, inbox_id: inbox.id)
      if existing_message
        Rails.logger.info "[UAZAPI] Message already exists, skipping: message_id=#{message_data[:message_id]}, existing_message_id=#{existing_message.id}"
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

    # if lock to single conversation is disabled, we will create a new conversation if previous conversation is resolved
    @conversation = if inbox.lock_to_single_conversation
                      @contact_inbox.conversations.last
                    else
                      @contact_inbox.conversations.where.not(status: :resolved).last
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

  def create_message(message_data)
    Rails.logger.info "[UAZAPI] Creating message in conversation_id=#{@conversation.id}"

    message_params = {
      account_id: inbox.account_id,
      inbox_id: inbox.id,
      conversation_id: @conversation.id,
      sender: @contact,
      content: message_data[:body],
      message_type: :incoming,
      source_id: message_data[:message_id].to_s if message_data[:message_id].present?,
      in_reply_to_external_id: message_data[:in_reply_to]
    }.compact

    message = @conversation.messages.create!(message_params)

    # Handle attachments if present
    if message_data[:media_url].present?
      Rails.logger.info "[UAZAPI] Processing attachment: media_url=#{message_data[:media_url]}"
      # Download and attach media
      # This is a simplified version - you may need to enhance this based on UazAPI's media format
      attachment = message.attachments.create!(
        account_id: inbox.account_id,
        file_type: determine_file_type(message_data[:type]),
        external_url: message_data[:media_url]
      )
      Rails.logger.info "[UAZAPI] Attachment created: attachment_id=#{attachment.id}"
    end

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
end

