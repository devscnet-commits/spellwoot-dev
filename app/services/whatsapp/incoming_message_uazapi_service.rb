# frozen_string_literal: true

class Whatsapp::IncomingMessageUazapiService
  pattr_initialize [:inbox!, :params!]

  def perform
    return if params[:message_id].blank?
    return if message_already_exists?
    return if params[:from_me] && !should_process_outgoing?

    set_contact
    return unless @contact

    ActiveRecord::Base.transaction do
      set_conversation
      create_message
    end
  end

  private

  def message_already_exists?
    inbox.messages.exists?(source_id: params[:message_id])
  end

  def should_process_outgoing?
    # Don't process messages sent by the API to avoid duplicates
    !params[:was_sent_by_api]
  end

  def set_contact
    phone_number = extract_phone_number
    return if phone_number.blank?

    contact_inbox = ::ContactInboxWithContactBuilder.new(
      source_id: phone_number,
      inbox: inbox,
      contact_attributes: {
        name: params[:sender_name] || phone_number,
        phone_number: "+#{phone_number}"
      }
    ).perform

    @contact_inbox = contact_inbox
    @contact = contact_inbox.contact

    update_contact_name_if_needed
  end

  def extract_phone_number
    phone = params[:phone].to_s
    # Remove @s.whatsapp.net suffix if present
    phone = phone.split('@').first if phone.include?('@')
    # Remove non-numeric characters
    phone.gsub(/\D/, '')
  end

  def update_contact_name_if_needed
    return if params[:sender_name].blank?
    return if @contact.name == params[:sender_name]

    phone_number = "+#{extract_phone_number}"
    return unless @contact.name == phone_number || @contact.name == extract_phone_number

    @contact.update!(name: params[:sender_name])
  end

  def set_conversation
    @conversation = if inbox.lock_to_single_conversation
                      @contact_inbox.conversations.last
                    else
                      @contact_inbox.conversations.where.not(status: :resolved).last
                    end

    return if @conversation

    @conversation = ::Conversation.create!(conversation_params)
  end

  def conversation_params
    {
      account_id: inbox.account_id,
      inbox_id: inbox.id,
      contact_id: @contact.id,
      contact_inbox_id: @contact_inbox.id
    }
  end

  def create_message
    @message = @conversation.messages.create!(
      content: message_content,
      account_id: inbox.account_id,
      inbox_id: inbox.id,
      message_type: params[:from_me] ? :outgoing : :incoming,
      sender: params[:from_me] ? nil : @contact,
      source_id: params[:message_id],
      in_reply_to_external_id: params[:quoted_message_id]
    )

    attach_media if params[:file_url].present?
  end

  def message_content
    params[:text].presence || ''
  end

  def attach_media
    return if params[:file_url].blank?

    file_type = determine_file_type
    attachment_file = download_file(params[:file_url])

    return if attachment_file.blank?

    @message.attachments.create!(
      account_id: @message.account_id,
      file_type: file_type,
      file: {
        io: attachment_file,
        filename: extract_filename(params[:file_url]),
        content_type: attachment_file.content_type
      }
    )
  rescue StandardError => e
    Rails.logger.error "[UAZAPI] Failed to attach media: #{e.message}"
  end

  def determine_file_type
    case params[:media_type]
    when 'image' then :image
    when 'video' then :video
    when 'audio' then :audio
    when 'sticker' then :image
    else :file
    end
  end

  def download_file(url)
    return nil if url.blank?

    response = Down.download(url, max_size: 40.megabytes)
    response
  rescue Down::Error => e
    Rails.logger.error "[UAZAPI] Failed to download file: #{e.message}"
    nil
  end

  def extract_filename(url)
    uri = URI.parse(url)
    File.basename(uri.path).presence || "attachment_#{Time.current.to_i}"
  rescue StandardError
    "attachment_#{Time.current.to_i}"
  end
end

