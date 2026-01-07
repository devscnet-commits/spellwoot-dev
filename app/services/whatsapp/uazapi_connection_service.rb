# frozen_string_literal: true

class Whatsapp::UazapiConnectionService
  attr_reader :inbox_name, :phone_number, :account

  def initialize(inbox_name:, phone_number:, account:)
    @inbox_name = inbox_name
    @phone_number = phone_number
    @account = account
  end

  def perform
    # Step 1: Create instance on UazAPI
    instance_data = create_uazapi_instance
    return { success: false, error: 'Failed to create UazAPI instance' } unless instance_data

    instance_token = instance_data['token']
    instance_id = instance_data.dig('instance', 'id') || instance_data['id']

    # Step 2: Create the WhatsApp channel
    channel = create_whatsapp_channel(instance_token, instance_id)
    return { success: false, error: 'Failed to create WhatsApp channel' } unless channel.persisted?

    # Step 3: Create the inbox
    inbox = create_inbox(channel)
    return { success: false, error: 'Failed to create inbox' } unless inbox.persisted?

    # Step 4: Connect to WhatsApp (get QR code)
    Rails.logger.info "[UAZAPI] Step 4: Connecting to WhatsApp..."
    provider_service = channel.provider_service
    connection_data = provider_service.connect
    Rails.logger.info "[UAZAPI] Connection data: #{connection_data}"

    {
      success: true,
      inbox: inbox,
      channel: channel,
      connection_data: connection_data,
      qr_code: extract_qr_code(connection_data),
      status: extract_status(connection_data)
    }
  rescue StandardError => e
    Rails.logger.error "[UAZAPI] Connection service error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    { success: false, error: e.message }
  end

  def self.get_status(channel)
    return nil unless channel.uazapi?

    provider_service = channel.provider_service
    status_data = provider_service.get_status

    return nil unless status_data

    {
      status: status_data.dig('instance', 'status') || status_data['status'],
      qr_code: status_data.dig('instance', 'qrcode'),
      pair_code: status_data.dig('instance', 'paircode'),
      connected: status_data.dig('status', 'connected') || false,
      logged_in: status_data.dig('status', 'loggedIn') || false,
      profile_name: status_data.dig('instance', 'profileName'),
      profile_pic_url: status_data.dig('instance', 'profilePicUrl')
    }
  end

  private

  def create_uazapi_instance
    instance_name = generate_instance_name
    Whatsapp::Providers::UazapiService.create_instance(instance_name)
  end

  def generate_instance_name
    # Create a unique instance name based on account and inbox name
    sanitized_name = inbox_name.parameterize
    "#{account.id}-#{sanitized_name}-#{SecureRandom.hex(4)}"
  end

  def create_whatsapp_channel(instance_token, instance_id)
    Channel::Whatsapp.create!(
      account_id: account.id,
      phone_number: formatted_phone_number,
      provider: 'uazapi',
      provider_config: {
        'uazapi_instance_token' => instance_token,
        'uazapi_instance_id' => instance_id
      }
    )
  end

  def create_inbox(channel)
    account.inboxes.create!(
      name: inbox_name,
      channel: channel
    )
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

