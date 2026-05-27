class Meta::ConversionsApiService
  API_URL = 'https://graph.facebook.com/v19.0'

  def initialize(conversation:)
    @conversation = conversation
    @pixel_id = ENV.fetch('META_PIXEL_ID', nil)
    @access_token = ENV.fetch('META_CONVERSIONS_API_TOKEN', nil)
  end

  def self.track_lead(conversation)
    new(conversation: conversation).perform
  end

  def perform
    return unless trackable?

    send_event
  end

  private

  def trackable?
    return false if @pixel_id.blank? || @access_token.blank?
    return false if ctwa_clid.blank?

    true
  end

  def ctwa_clid
    @conversation.custom_attributes&.dig('ctwa_clid')
  end

  def phone_number
    @conversation.contact&.phone_number&.gsub(/\D/, '')
  end

  def send_event
    payload = {
      data: [
        {
          event_name: 'Lead',
          event_time: Time.current.to_i,
          action_source: 'business_messaging',
          messaging_channel: 'whatsapp',
          user_data: {
            ph: [Digest::SHA256.hexdigest(phone_number.to_s)],
            ctwa_clid: ctwa_clid
          }
        }
      ]
    }

    response = HTTParty.post(
      "#{API_URL}/#{@pixel_id}/events",
      headers: { 'Content-Type' => 'application/json' },
      body: payload.merge(access_token: @access_token).to_json
    )

    if response.success?
      Rails.logger.info "[META] Lead event sent for conversation #{@conversation.id}"
    else
      Rails.logger.error "[META] Failed to send Lead event: #{response.body}"
    end

    response
  rescue StandardError => e
    Rails.logger.error "[META] Error sending Lead event: #{e.message}"
  end
end