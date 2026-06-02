class Meta::ConversionsApiService
  API_URL = 'https://graph.facebook.com/v19.0'

  def initialize(conversation:, event_name: 'Lead', value: nil, currency: nil)
    @conversation = conversation
    @account = conversation.account
    @event_name = event_name
    @value = value
    @currency = currency || meta_settings.dig('currency') || 'BRL'
    @pixel_id = ENV.fetch('META_PIXEL_ID', nil)
    @access_token = ENV.fetch('META_CONVERSIONS_API_TOKEN', nil)
  end

  def self.track_lead(conversation)
    new(conversation: conversation, event_name: 'Lead').perform
  end

  def self.track_purchase(conversation, value: nil)
    new(conversation: conversation, event_name: 'Purchase', value: value).perform
  end

  def perform
    unless trackable?
      Rails.logger.info "[CAPI] conv=#{@conversation.id} skipped reason=#{skip_reason}"
      return
    end

    if already_sent?
      Rails.logger.info "[CAPI] conv=#{@conversation.id} skipped reason=already_sent"
      return
    end

    response = post_to_meta(build_payload)
    mark_as_sent! if response&.success?
    response
  end

  private

  def trackable?
    return false if @pixel_id.blank? || @access_token.blank?
    return false if ctwa_clid.blank?

    true
  end

  def skip_reason
    return 'missing_pixel_or_token' if @pixel_id.blank? || @access_token.blank?
    return 'missing_ctwa_clid' if ctwa_clid.blank?
  end

  def already_sent?
    @conversation.additional_attributes&.dig('meta_conversion', 'sent') == true
  end

  def ctwa_clid
    @conversation.custom_attributes&.dig('ctwa_clid') ||
      @conversation.additional_attributes&.dig('attribution', 'ctwa_clid')
  end

  def contact_phone
    @conversation.contact&.phone_number&.gsub(/\D/, '')
  end

  def meta_settings
    @account.settings&.dig('meta_conversion_settings') || {}
  end

  def hashed(value)
    return nil if value.blank?

    Digest::SHA256.hexdigest(value.to_s.downcase.strip)
  end

  def enrichment_user_data
    fields = meta_settings.dig('enrichment_fields') || {}
    fields.each_with_object({}) do |(meta_key, attr_key), acc|
      raw = @conversation.custom_attributes&.dig(attr_key) ||
            @conversation.contact&.custom_attributes&.dig(attr_key)
      acc[meta_key.to_sym] = [hashed(raw)] if raw.present?
    end
  end

  def build_payload
    user_data = {
      ctwa_clid: ctwa_clid,
      ph: [hashed(contact_phone)]
    }.merge(enrichment_user_data).compact

    event = {
      event_name: @event_name,
      event_time: Time.current.to_i,
      action_source: 'business_messaging',
      messaging_channel: 'whatsapp',
      user_data: user_data
    }

    event[:custom_data] = { currency: @currency, value: @value.to_f } if @event_name == 'Purchase'

    body = { data: [event] }
    test_code = ENV.fetch('META_TEST_EVENT_CODE', nil)
    body[:test_event_code] = test_code if test_code.present?
    body
  end

  def post_to_meta(payload)
    response = HTTParty.post(
      "#{API_URL}/#{@pixel_id}/events",
      headers: { 'Content-Type' => 'application/json' },
      body: payload.merge(access_token: @access_token).to_json
    )

    if response.success?
      Rails.logger.info "[CAPI] conv=#{@conversation.id} event=#{@event_name} status=sent ctwa_clid=#{ctwa_clid}"
    else
      Rails.logger.error "[CAPI] conv=#{@conversation.id} event=#{@event_name} status=failed body=#{response.body}"
    end

    response
  rescue StandardError => e
    Rails.logger.error "[CAPI] conv=#{@conversation.id} event=#{@event_name} status=error message=#{e.message}"
    nil
  end

  def mark_as_sent!
    @conversation.update!(
      additional_attributes: (@conversation.additional_attributes || {}).deep_merge(
        'meta_conversion' => {
          'sent' => true,
          'event_name' => @event_name,
          'sent_at' => Time.current.iso8601,
          'ctwa_clid' => ctwa_clid
        }
      )
    )
  end
end
