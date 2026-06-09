class Meta::ConversionsApiService
  API_URL = 'https://graph.facebook.com/v19.0'

  def initialize(conversation:, event_name: 'Lead', value: nil, currency: nil, event_id: nil)
    @conversation = conversation
    @account = conversation.account
    @event_name = event_name
    @value = value
    @event_id = event_id
    @currency = currency || meta_settings.dig('currency') || 'BRL'
    meta_config = IntegrationSettingsService.get_config(@conversation.account_id, 'meta')
    @pixel_id = meta_config['pixelId']
    @access_token = meta_config['accessToken']
    @test_event_code = meta_config.fetch('testEventCode', ENV.fetch('META_TEST_EVENT_CODE', nil))
  end

  def self.track_lead(conversation)
    new(conversation: conversation, event_name: 'Lead', event_id: "lead-#{conversation.id}").perform
  end

  # event_name/event_id let the close flow fire a per-state conversion (e.g. Purchase keyed on the
  # resolution state) so Lead-on-arrival and the closing conversion can coexist without deduping
  # each other.
  def self.track_purchase(conversation, value: nil, event_name: 'Purchase', event_id: nil)
    new(conversation: conversation, event_name: event_name, value: value,
        event_id: event_id || "#{event_name.to_s.downcase}-#{conversation.id}").perform
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
    return false unless master_enabled?
    return false if @pixel_id.blank? || @access_token.blank?
    return false if ctwa_clid.blank?

    true
  end

  def skip_reason
    return 'master_disabled' unless master_enabled?
    return 'missing_pixel_or_token' if @pixel_id.blank? || @access_token.blank?
    return 'missing_ctwa_clid' if ctwa_clid.blank?
  end

  # Account-level master switch. When off, nothing is sent to Meta — neither the
  # Lead-on-arrival event nor any per-flow closing conversion.
  def master_enabled?
    meta_settings['enabled'] == true
  end

  # Dedup per event_id so different events (Lead vs the closing conversion) don't block each other,
  # while re-firing the same event (e.g. close→reopen→close) stays idempotent. Falls back to the
  # legacy single flag when no event_id is provided.
  def already_sent?
    return sent_event_ids.include?(@event_id) if @event_id.present?

    @conversation.additional_attributes&.dig('meta_conversion', 'sent') == true
  end

  def sent_event_ids
    Array(@conversation.additional_attributes&.dig('meta_conversion', 'sent_events'))
  end

  def ctwa_clid
    @conversation.custom_attributes&.dig('ctwa_clid') ||
      @conversation.additional_attributes&.dig('attribution', 'ctwa_clid')
  end

  def contact_phone
    @conversation.contact&.phone_number&.gsub(/\D/, '')
  end

  def contact_first_name
    @conversation.contact&.name&.split&.first
  end

  def meta_settings
    @account.settings&.dig('meta_conversion_settings') || {}
  end

  def hashed(value)
    return nil if value.blank?

    Digest::SHA256.hexdigest(value.to_s.downcase.strip)
  end

  AUTO_CONTACT_FIELDS = %w[fn ph].freeze

  def enrichment_user_data
    fields = (meta_settings.dig('enrichment_fields') || {}).reject { |k, _| AUTO_CONTACT_FIELDS.include?(k.to_s) }
    fields.each_with_object({}) do |(meta_key, attr_key), acc|
      raw = @conversation.custom_attributes&.dig(attr_key) ||
            @conversation.contact&.custom_attributes&.dig(attr_key)
      acc[meta_key.to_sym] = [hashed(raw)] if raw.present?
    end
  end

  def build_payload
    auto_data = {
      ctwa_clid: ctwa_clid,
      ph: contact_phone.present? ? [hashed(contact_phone)] : nil,
      fn: contact_first_name.present? ? [hashed(contact_first_name)] : nil,
    }
    user_data = enrichment_user_data.merge(auto_data).compact

    event = {
      event_name: @event_name,
      event_time: Time.current.to_i,
      action_source: 'business_messaging',
      messaging_channel: 'whatsapp',
      user_data: user_data
    }

    # Deterministic event_id lets Meta deduplicate server-side (close→reopen→close counts once).
    event[:event_id] = @event_id if @event_id.present?
    event[:custom_data] = { currency: @currency, value: @value.to_f } if @event_name == 'Purchase'

    body = { data: [event] }
    body[:test_event_code] = @test_event_code if @test_event_code.present?
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

    record_audit(payload, response.success? ? 'sent' : 'failed', response.body)
    response
  rescue StandardError => e
    Rails.logger.error "[CAPI] conv=#{@conversation.id} event=#{@event_name} status=error message=#{e.message}"
    record_audit(payload, 'error', e.message)
    nil
  end

  # Persist an audit row per attempt. The payload here excludes the access token (added only at
  # POST time). Never let auditing break the send path.
  def record_audit(payload, status, response_body)
    MetaConversionEvent.create!(
      account_id: @conversation.account_id,
      conversation_id: @conversation.id,
      event_name: @event_name,
      event_id: @event_id,
      status: status,
      payload: payload,
      response: response_body.to_s
    )
  rescue StandardError => e
    Rails.logger.error "[CAPI] conv=#{@conversation.id} audit_failed message=#{e.message}"
  end

  def mark_as_sent!
    events = sent_event_ids
    events |= [@event_id] if @event_id.present?
    @conversation.update!(
      additional_attributes: (@conversation.additional_attributes || {}).deep_merge(
        'meta_conversion' => {
          'sent' => true,
          'event_name' => @event_name,
          'sent_at' => Time.current.iso8601,
          'ctwa_clid' => ctwa_clid,
          'sent_events' => events
        }
      )
    )
  end
end
