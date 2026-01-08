# frozen_string_literal: true

class Whatsapp::Providers::UazapiService < Whatsapp::Providers::BaseService
  def send_message(phone_number, message)
    @message = message

    if message.attachments.present?
      send_attachment_message(phone_number, message)
    elsif message.content_type == 'input_select'
      send_interactive_text_message(phone_number, message)
    else
      send_text_message(phone_number, message)
    end
  end

  def send_template(phone_number, template_info, message)
    # UazAPI doesn't support WhatsApp Business templates in the same way
    # For now, send as a regular text message
    send_text_message(phone_number, message)
  end

  def sync_templates
    # UazAPI doesn't support WhatsApp Business templates
    whatsapp_channel.mark_message_templates_updated
  end

  def validate_provider_config?
    return true if whatsapp_channel.provider_config['uazapi_instance_token'].present?

    false
  end

  def api_headers
    {
      'Content-Type' => 'application/json',
      'token' => instance_token
    }
  end

  def media_url(media_id, _phone_number_id = nil)
    media_id
  end

  # UazAPI specific methods

  def self.create_instance(name)
    url = "#{base_url}/instance/init"
    Rails.logger.info "[UAZAPI] Creating instance: #{name} at #{url}"

    response = HTTParty.post(
      url,
      headers: admin_headers,
      body: { name: name }.to_json
    )

    Rails.logger.info "[UAZAPI] Response code: #{response.code}, body: #{response.body}"

    unless response.success?
      Rails.logger.error "[UAZAPI] Failed to create instance: #{response.body}"
      return nil
    end

    response.parsed_response
  end

  def connect(phone_number = nil)
    body = phone_number.present? ? { phone: phone_number } : {}
    url = "#{base_url}/instance/connect"

    Rails.logger.info "[UAZAPI] Connecting instance at #{url}"
    Rails.logger.info "[UAZAPI] Connect headers: #{api_headers.except('token').merge('token' => '***')}"

    response = HTTParty.post(
      url,
      headers: api_headers,
      body: body.to_json
    )

    Rails.logger.info "[UAZAPI] Connect response code: #{response.code}"
    Rails.logger.info "[UAZAPI] Connect response body: #{response.body}"

    return nil unless response.success?

    response.parsed_response
  end

  def get_status
    response = HTTParty.get(
      "#{base_url}/instance/status",
      headers: api_headers
    )

    return nil unless response.success?

    response.parsed_response
  end

  def disconnect
    response = HTTParty.post(
      "#{base_url}/instance/disconnect",
      headers: api_headers
    )

    response.success?
  end

  def delete_instance
    Rails.logger.info "[UAZAPI] Deleting instance..."

    response = HTTParty.delete(
      "#{base_url}/instance",
      headers: api_headers
    )

    Rails.logger.info "[UAZAPI] Delete response: #{response.code} - #{response.body}"

    response.success?
  end

  private

  def send_text_message(phone_number, message)
    formatted_phone = format_phone_number(phone_number)

    body = {
      phone: formatted_phone,
      message: message.outgoing_content
    }

    # Add reply context if present
    reply_to = message.content_attributes&.dig(:in_reply_to_external_id)
    body[:quotedMsgId] = reply_to if reply_to.present?

    response = HTTParty.post(
      "#{base_url}/message/text",
      headers: api_headers,
      body: body.to_json
    )

    process_uazapi_response(response, message)
  end

  def send_attachment_message(phone_number, message)
    attachment = message.attachments.first
    formatted_phone = format_phone_number(phone_number)
    type = attachment_type(attachment.file_type)

    body = {
      phone: formatted_phone,
      url: attachment.download_url,
      caption: message.outgoing_content
    }

    endpoint = case type
               when 'image' then '/message/image'
               when 'video' then '/message/video'
               when 'audio' then '/message/audio'
               else '/message/document'
               end

    body[:filename] = attachment.file.filename if type == 'document'

    response = HTTParty.post(
      "#{base_url}#{endpoint}",
      headers: api_headers,
      body: body.to_json
    )

    process_uazapi_response(response, message)
  end

  def send_interactive_text_message(phone_number, message)
    # UazAPI supports interactive messages with buttons/lists
    items = message.content_attributes['items']

    if items.length <= 3
      send_button_message(phone_number, message, items)
    else
      send_list_message(phone_number, message, items)
    end
  end

  def send_button_message(phone_number, message, items)
    formatted_phone = format_phone_number(phone_number)

    buttons = items.map do |item|
      { id: item['value'], text: item['title'] }
    end

    response = HTTParty.post(
      "#{base_url}/message/button",
      headers: api_headers,
      body: {
        phone: formatted_phone,
        message: message.outgoing_content,
        buttons: buttons
      }.to_json
    )

    process_uazapi_response(response, message)
  end

  def send_list_message(phone_number, message, items)
    formatted_phone = format_phone_number(phone_number)

    rows = items.map do |item|
      { id: item['value'], title: item['title'] }
    end

    response = HTTParty.post(
      "#{base_url}/message/list",
      headers: api_headers,
      body: {
        phone: formatted_phone,
        message: message.outgoing_content,
        buttonText: I18n.t('conversations.messages.whatsapp.list_button_label'),
        sections: [{ rows: rows }]
      }.to_json
    )

    process_uazapi_response(response, message)
  end

  def process_uazapi_response(response, message)
    if response.success?
      parsed = response.parsed_response
      # UazAPI returns messageid in the response
      parsed['messageid'] || parsed['id']
    else
      handle_uazapi_error(response, message)
      nil
    end
  end

  def handle_uazapi_error(response, message)
    Rails.logger.error "[UAZAPI] Error: #{response.body}"
    return if message.blank?

    error_msg = response.parsed_response&.dig('error') || 'Unknown error'
    message.external_error = error_msg
    message.status = :failed
    message.save!
  end

  def error_message(response)
    response.parsed_response&.dig('error')
  end

  def format_phone_number(phone_number)
    # Remove any non-numeric characters and ensure it starts without +
    phone_number.to_s.gsub(/\D/, '')
  end

  def attachment_type(file_type)
    case file_type
    when 'image' then 'image'
    when 'video' then 'video'
    when 'audio' then 'audio'
    else 'document'
    end
  end

  def instance_token
    whatsapp_channel.provider_config['uazapi_instance_token']
  end

  def base_url
    self.class.base_url
  end

  def self.base_url
    ENV.fetch('UAZAPI_BASE_URL', 'https://free.uazapi.com')
  end

  def self.admin_headers
    {
      'Content-Type' => 'application/json',
      'admintoken' => ENV.fetch('UAZAPI_ADMIN_TOKEN', nil)
    }
  end

  def self.configure_chatwoot_integration(instance_token, chatwoot_config)
    url = "#{base_url}/chatwoot/config"
    
    # Log antes de fazer a requisição (sem token sensível)
    log_config = chatwoot_config.dup
    log_config['access_token'] = "#{log_config['access_token'][0..10]}..." if log_config['access_token'].present?
    Rails.logger.info "[UAZAPI] Configuring Chatwoot integration for instance"
    Rails.logger.info "[UAZAPI] URL: #{url}"
    Rails.logger.info "[UAZAPI] Config: #{log_config.to_json}"

    headers = {
      'Content-Type' => 'application/json',
      'token' => instance_token
    }

    begin
      response = HTTParty.put(
        url,
        headers: headers,
        body: chatwoot_config.to_json
      )

      Rails.logger.info "[UAZAPI] Chatwoot config response code: #{response.code}"
      Rails.logger.info "[UAZAPI] Chatwoot config response body: #{response.body}"

      unless response.success?
        Rails.logger.error "[UAZAPI] Failed to configure Chatwoot integration: #{response.body}"
        return nil
      end

      parsed_response = response.parsed_response
      webhook_url = parsed_response['chatwoot_inbox_webhook_url']
      
      Rails.logger.info "[UAZAPI] Chatwoot integration configured successfully"
      Rails.logger.info "[UAZAPI] Webhook URL: #{webhook_url}" if webhook_url.present?

      parsed_response
    rescue StandardError => e
      Rails.logger.error "[UAZAPI] Error configuring Chatwoot integration: #{e.message}"
      Rails.logger.error "[UAZAPI] #{e.backtrace.join("\n")}"
      nil
    end
  end

  def self.get_chatwoot_config(instance_token)
    url = "#{base_url}/chatwoot/config"
    
    Rails.logger.info "[UAZAPI] Getting Chatwoot integration status"
    Rails.logger.info "[UAZAPI] URL: #{url}"

    headers = {
      'Content-Type' => 'application/json',
      'token' => instance_token
    }

    begin
      response = HTTParty.get(
        url,
        headers: headers
      )

      Rails.logger.info "[UAZAPI] Chatwoot config GET response code: #{response.code}"
      Rails.logger.info "[UAZAPI] Chatwoot config GET response body: #{response.body}"

      unless response.success?
        Rails.logger.error "[UAZAPI] Failed to get Chatwoot integration status: #{response.body}"
        return nil
      end

      response.parsed_response
    rescue StandardError => e
      Rails.logger.error "[UAZAPI] Error getting Chatwoot integration status: #{e.message}"
      Rails.logger.error "[UAZAPI] #{e.backtrace.join("\n")}"
      nil
    end
  end
end

