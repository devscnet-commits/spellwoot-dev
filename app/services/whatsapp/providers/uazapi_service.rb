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

  def self.create_instance(name, account_id: nil)
    url = "#{base_url(account_id)}/instance/init"
    Rails.logger.info "[UAZAPI] Creating instance: #{name} at #{url}"

    response = HTTParty.post(
      url,
      headers: admin_headers(account_id),
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
    body = {
      number: format_phone_number(phone_number),
      text: message.outgoing_content
    }

    # Add reply context if present
    reply_to = message.content_attributes&.dig(:in_reply_to_external_id)
    body[:replyid] = reply_to if reply_to.present?

    response = HTTParty.post(
      "#{base_url}/send/text",
      headers: api_headers,
      body: body.to_json
    )

    process_uazapi_response(response, message)
  end

  def send_attachment_message(phone_number, message)
    attachment = message.attachments.first
    type = attachment_type(attachment.file_type)

    body = {
      number: format_phone_number(phone_number),
      type: type,
      file: attachment.download_url
    }
    body[:text] = message.outgoing_content if message.outgoing_content.present?
    body[:docName] = attachment.file.filename.to_s if type == 'document'

    response = HTTParty.post(
      "#{base_url}/send/media",
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
    response = HTTParty.post(
      "#{base_url}/send/menu",
      headers: api_headers,
      body: {
        number: format_phone_number(phone_number),
        type: 'button',
        text: message.outgoing_content,
        choices: items.map { |item| "#{item['title']}|#{item['value']}" }
      }.to_json
    )

    process_uazapi_response(response, message)
  end

  def send_list_message(phone_number, message, items)
    response = HTTParty.post(
      "#{base_url}/send/menu",
      headers: api_headers,
      body: {
        number: format_phone_number(phone_number),
        type: 'list',
        text: message.outgoing_content,
        listButton: I18n.t('conversations.messages.whatsapp.list_button_label'),
        choices: items.map { |item| "#{item['title']}|#{item['value']}" }
      }.to_json
    )

    process_uazapi_response(response, message)
  end

  def process_uazapi_response(response, message)
    parsed = response.parsed_response
    message_id = parsed&.dig('messageid') || parsed&.dig('id')

    Rails.logger.info "[UAZAPI] Send response: status=#{response.code}, message_id=#{message_id}, body=#{response.body.truncate(200)}"

    if message_id.present?
      # Message was accepted by UazAPI (has an ID) regardless of HTTP status
      message.update!(source_id: message_id.to_s) if message.present?
      message_id
    elsif response.success?
      # 2xx but no message ID — log but don't mark as failed
      Rails.logger.warn "[UAZAPI] Success response but no message_id returned: #{response.body.truncate(200)}"
      nil
    else
      handle_uazapi_error(response, message)
      nil
    end
  end

  def handle_uazapi_error(response, message)
    Rails.logger.error "[UAZAPI] Error: #{response.body}"
    return if message.blank?

    error_msg = case response.code.to_i
                when 401
                  'Sessão expirada. Reconecte a caixa do WhatsApp'
                when 403
                  'Sem permissão para enviar mensagens nesta conta'
                when 404
                  'Instância não encontrada. Verifique a conexão da caixa'
                when 405
                  'Caixa desconectada. Reconecte o WhatsApp'
                when 422
                  'Número de telefone inválido ou não está no WhatsApp'
                when 429
                  'Limite de mensagens atingido. Aguarde alguns minutos'
                when 500, 502, 503
                  'Erro no servidor do WhatsApp. Tente reenviar em instantes'
                else
                  response.parsed_response&.dig('error') || 'Falha ao enviar mensagem'
                end

    message.external_error = error_msg
    message.status = :failed
    message.save!
  end

  def error_message(response)
    response.parsed_response&.dig('error')
  end

  def format_phone_number(phone_number)
    number = phone_number.to_s
    # Don't mangle JIDs / group ids (e.g. "1203...@g.us"); only strip plain phone numbers.
    return number if number.include?('@')

    number.gsub(/\D/, '')
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
    self.class.base_url(whatsapp_channel.account_id)
  end

  # Resolves credentials using the 3-tier chain:
  # account settings → global settings → environment variables.
  # Falls back gracefully so ENV-only installs keep working.
  def self.credentials_for(account_id = nil)
    if account_id.present?
      config = IntegrationSettingsService.get_config(account_id, 'uazapi')
      db_account = IntegrationSettingsService.load_db(account_id, 'uazapi')
      db_global  = IntegrationSettingsService.load_db(nil, 'uazapi')
      source = (db_account.any? || db_global.any?) ? 'account/global settings' : 'environment variables'
      Rails.logger.info "[UAZAPI] Credential source: #{source} (account_id=#{account_id})"
    else
      config = {}
      Rails.logger.info '[UAZAPI] Credential source: environment variables (no account context)'
    end

    # A masked token (contains '*') is never a real credential — fall back to ENV.
    saved_token = config['token'].to_s
    saved_token = nil if saved_token.include?('*')

    {
      base_url:         config['apiUrl'].presence         || ENV.fetch('UAZAPI_BASE_URL', 'https://free.uazapi.com'),
      admin_token:      saved_token.presence              || ENV.fetch('UAZAPI_ADMIN_TOKEN', nil),
      webhook_base_url: config['webhookBaseUrl'].presence || ENV.fetch('UAZAPI_WEBHOOK_BASE_URL', nil)
    }
  end

  def self.base_url(account_id = nil)
    credentials_for(account_id)[:base_url]
  end

  def self.admin_headers(account_id = nil)
    {
      'Content-Type' => 'application/json',
      'admintoken'   => credentials_for(account_id)[:admin_token]
    }
  end

  def self.configure_chatwoot_integration(instance_token, chatwoot_config, account_id: nil)
    url = "#{base_url(account_id)}/chatwoot/config"
    
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

  def self.get_chatwoot_config(instance_token, account_id: nil)
    url = "#{base_url(account_id)}/chatwoot/config"
    
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

