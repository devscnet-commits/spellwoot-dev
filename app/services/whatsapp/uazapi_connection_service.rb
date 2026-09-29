# frozen_string_literal: true

class Whatsapp::UazapiConnectionService
  attr_reader :inbox_name, :phone_number, :account

  def initialize(inbox_name:, phone_number:, account:)
    @inbox_name = inbox_name
    @phone_number = phone_number
    @account = account
  end

  def perform
    Rails.logger.info "[UAZAPI] Starting inbox creation process for account_id=#{account.id}, inbox_name=#{inbox_name}, phone_number=#{phone_number}"

    # Step 0: Check for conflicting instances before creating
    Current.account = account
    conflicting_count = self.class.check_for_conflicting_instances(formatted_phone_number)
    if conflicting_count > 0
      Rails.logger.warn "[UAZAPI] Warning: Found #{conflicting_count} already connected instance(s) for phone #{formatted_phone_number}"
      Rails.logger.warn "[UAZAPI] This may cause 'logged out from another device' errors"
    end

    # Step 1: Create instance on UazAPI
    Rails.logger.info "[UAZAPI] Step 1: Creating instance on UazAPI..."
    instance_data = create_uazapi_instance
    unless instance_data
      Rails.logger.error "[UAZAPI] Failed to create UazAPI instance"
      return { success: false, error: 'Failed to create UazAPI instance' }
    end

    instance_token = instance_data['token']
    instance_id = instance_data.dig('instance', 'id') || instance_data['id']
    Rails.logger.info "[UAZAPI] Instance created successfully: instance_id=#{instance_id}, token=#{instance_token[0..10]}..."

    # Step 2: Create the API channel
    Rails.logger.info "[UAZAPI] Step 2: Creating Channel::Api..."
    channel = create_api_channel(instance_token, instance_id)
    unless channel.persisted?
      Rails.logger.error "[UAZAPI] Failed to create API channel"
      return { success: false, error: 'Failed to create API channel' }
    end
    Rails.logger.info "[UAZAPI] Channel::Api created successfully: channel_id=#{channel.id}, identifier=#{channel.identifier}"

    # Step 3: Create the inbox
    Rails.logger.info "[UAZAPI] Step 3: Creating inbox..."
    inbox = create_inbox(channel)
    unless inbox.persisted?
      Rails.logger.error "[UAZAPI] Failed to create inbox"
      return { success: false, error: 'Failed to create inbox' }
    end
    Rails.logger.info "[UAZAPI] Inbox created successfully: inbox_id=#{inbox.id}"

    # Step 4: Configure Chatwoot integration via /chatwoot/config
    Rails.logger.info "[UAZAPI] Step 4: Configuring Chatwoot integration..."
    chatwoot_config_result = configure_chatwoot_integration(inbox, instance_token)
    webhook_url = chatwoot_config_result&.dig('chatwoot_inbox_webhook_url')

    if webhook_url.present?
      Rails.logger.info "[UAZAPI] Chatwoot integration configured successfully, webhook_url=#{webhook_url}"
      channel.update!(webhook_url: webhook_url)
      channel.reload
      Rails.logger.info "[UAZAPI] Updated Channel::Api webhook_url: channel_id=#{channel.id}, webhook_url=#{channel.webhook_url}"
    else
      Rails.logger.warn "[UAZAPI] Chatwoot integration configuration failed or webhook_url not returned"
    end

    # Step 5: Connect to WhatsApp (get QR code)
    Rails.logger.info "[UAZAPI] Step 5: Connecting instance to WhatsApp..."
    connection_data = connect_instance(instance_token)
    Rails.logger.info "[UAZAPI] Connection data received: status=#{extract_status(connection_data)}, " \
                       "qr_code_available=#{extract_qr_code(connection_data).present?}"

    {
      success: true,
      inbox: inbox,
      channel: channel,
      connection_data: connection_data,
      qr_code: extract_qr_code(connection_data),
      status: extract_status(connection_data),
      webhook_url: webhook_url
    }
  rescue StandardError => e
    Rails.logger.error "[UAZAPI] Connection service error: #{e.message}"
    Rails.logger.error "[UAZAPI] #{e.backtrace.join("\n")}"
    { success: false, error: e.message }
  end

  def self.get_status(channel)
    return nil unless channel.is_a?(Channel::Api)
    return nil unless channel.additional_attributes&.dig('uazapi_instance_token').present?

    instance_token = channel.additional_attributes['uazapi_instance_token']
    base_url = Whatsapp::Providers::UazapiService.base_url(channel.account_id)

    headers = {
      'Content-Type' => 'application/json',
      'token' => instance_token
    }

    begin
      # Get instance status
      response = HTTParty.get(
        "#{base_url}/instance/status",
        headers: headers
      )

      return nil unless response.success?

      status_data = response.parsed_response
      instance_status = {
        status: status_data.dig('instance', 'status') || status_data['status'],
        qr_code: status_data.dig('instance', 'qrcode'),
        pair_code: status_data.dig('instance', 'paircode'),
        connected: status_data.dig('status', 'connected') || false,
        logged_in: status_data.dig('status', 'loggedIn') || false,
        profile_name: status_data.dig('instance', 'profileName'),
        profile_pic_url: status_data.dig('instance', 'profilePicUrl')
      }

      # Get Chatwoot integration status
      chatwoot_config = Whatsapp::Providers::UazapiService.get_chatwoot_config(instance_token, account_id: channel.account_id)
      integration_status = chatwoot_config&.dig('integration_status') || {}

      instance_status[:integration_status] = integration_status
      instance_status[:integration_error] = integration_status['status'] == 'error'

      instance_status
    rescue StandardError => e
      Rails.logger.error "[UAZAPI] Error getting status: #{e.message}"
      Rails.logger.error "[UAZAPI] #{e.backtrace.join("\n")}"
      nil
    end
  end

  def self.check_for_conflicting_instances(phone_number)
    # Check if there are other API channels with the same phone number that are connected
    conflicting_channels = Channel::Api.where(
      account_id: Current.account&.id
    ).where.not(id: nil)

    connected_count = 0
    conflicting_channels.each do |ch|
      phone_in_attrs = ch.additional_attributes&.dig('phone_number')
      next unless phone_in_attrs == phone_number

      begin
        status = get_status(ch)
        connected_count += 1 if status && status[:status] == 'connected'
      rescue StandardError => e
        Rails.logger.warn "[UAZAPI] Failed to check status for channel #{ch.id}: #{e.message}"
      end
    end

    if connected_count > 0
      Rails.logger.warn "[UAZAPI] Found #{connected_count} already connected instance(s) for phone #{phone_number}"
    end

    connected_count
  end

  private

  def create_uazapi_instance
    instance_name = generate_instance_name
    Whatsapp::Providers::UazapiService.create_instance(instance_name, account_id: account.id)
  end

  def generate_instance_name
    # Create a unique instance name based on account and inbox name
    sanitized_name = inbox_name.parameterize
    "#{account.id}-#{sanitized_name}-#{SecureRandom.hex(4)}"
  end

  def create_api_channel(instance_token, instance_id)
    channel = Channel::Api.create!(
      account_id: account.id,
      additional_attributes: {
        'uazapi_instance_token' => instance_token,
        'uazapi_instance_id' => instance_id,
        'phone_number' => formatted_phone_number
      }
    )
    channel
  end

  def create_inbox(channel)
    account.inboxes.create!(
      name: inbox_name,
      channel: channel
    )
  end

  def configure_chatwoot_integration(inbox, instance_token)
    return nil unless Current.user.present?

    access_token = Current.user.access_token&.token
    unless access_token.present?
      Rails.logger.warn "[UAZAPI] Access token not available for user_id=#{Current.user.id}"
      return nil
    end

    creds = Whatsapp::Providers::UazapiService.credentials_for(account.id)
    chatwoot_url = creds[:webhook_base_url] ||
                   ENV.fetch('FRONTEND_URL', nil) ||
                   (ENV['HEROKU_APP_NAME'].present? ? "https://#{ENV['HEROKU_APP_NAME']}.herokuapp.com" : nil)

    unless chatwoot_url.present?
      Rails.logger.warn '[UAZAPI] No webhook base URL configured (UAZAPI_WEBHOOK_BASE_URL / FRONTEND_URL missing)'
      return nil
    end

    chatwoot_config = {
      enabled: true,
      url: chatwoot_url,
      access_token: access_token,
      account_id: account.id,
      inbox_id: inbox.id,
      ignore_groups: false,
      sign_messages: true,
      create_new_conversation: true
    }

    Whatsapp::Providers::UazapiService.configure_chatwoot_integration(instance_token, chatwoot_config, account_id: account.id)
  end

  def connect_instance(instance_token)
    base_url = Whatsapp::Providers::UazapiService.base_url(account.id)
    headers = {
      'Content-Type' => 'application/json',
      'token' => instance_token
    }

    # Don't send phone number - just generate QR code
    response = HTTParty.post(
      "#{base_url}/instance/connect",
      headers: headers,
      body: {}.to_json
    )

    return nil unless response.success?

    response.parsed_response
  end

  def formatted_phone_number
    # Ensure phone number is in the correct format
    phone_number.to_s.gsub(/\D/, '')
  end

  def extract_qr_code(connection_data)
    return nil unless connection_data

    connection_data.dig('instance', 'qrcode') || connection_data['qrcode']
  end

  def extract_status(connection_data)
    return 'disconnected' unless connection_data

    connection_data.dig('instance', 'status') || 'connecting'
  end
end

