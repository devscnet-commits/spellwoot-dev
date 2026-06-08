class Attribution::ConversationAttributionService
  def self.process(conversation:, referral:, provider: 'meta')
    return if conversation.blank?

    if referral.blank?
      Rails.logger.info "[CAPI] conv=#{conversation.id} attribution skipped reason=no_referral"
      return
    end

    Rails.logger.info "[CAPI] conv=#{conversation.id} referral_received ctwa_clid=#{referral['ctwa_clid'].presence || 'none'} source=#{referral['source_id']}"

    attribution_payload = {
      attribution: {
        provider: provider,
        utm_source: 'Meta_Ads',
        utm_medium: referral['media_type'],
        utm_campaign: referral['headline'],
        utm_content: referral['source_id'],
        ctwa_clid: referral['ctwa_clid'],
        media_url: referral['source_url'] || referral['video_url'],
        thumbnail_url: referral['thumbnail_url'],
        ad_body: referral['body'],
        captured_at: Time.current
      }.compact
    }

    conversation.update!(
      additional_attributes:
        (conversation.additional_attributes || {})
          .deep_merge(attribution_payload)
    )

    custom_attrs = (conversation.custom_attributes || {}).merge(
      'utm_source' => 'Meta_Ads',
      'utm_medium' => referral['media_type'],
      'utm_campaign' => referral['headline'],
      'utm_content' => referral['source_id'],
      'ctwa_clid' => referral['ctwa_clid']
    ).compact

    conversation.update!(custom_attributes: custom_attrs)
    track_lead_on_arrival(conversation, custom_attrs)
  end

  def self.track_lead_on_arrival(conversation, custom_attrs)
    if custom_attrs['ctwa_clid'].blank?
      Rails.logger.info "[CAPI] conv=#{conversation.id} lead_job skipped reason=no_ctwa_clid"
      return
    end

    unless lead_on_arrival_enabled?(conversation.account)
      Rails.logger.info "[CAPI] conv=#{conversation.id} lead_job skipped reason=lead_on_arrival_disabled"
      return
    end

    Rails.logger.info "[CAPI] conv=#{conversation.id} lead_job enqueued"
    Meta::TrackLeadJob.perform_later(conversation.id)
  end
  private_class_method :track_lead_on_arrival

  # Lead-on-arrival is now an independent toggle so it can coexist with the closing conversion.
  # The explicit flag wins; absent it, fall back to the legacy mutually-exclusive strategy radio.
  def self.lead_on_arrival_enabled?(account)
    settings = account.settings&.dig('meta_conversion_settings') || {}
    return settings['lead_on_arrival'] == true if settings.key?('lead_on_arrival')

    strategy = settings['strategy']
    strategy.nil? || strategy == 'on_arrival'
  end
  private_class_method :lead_on_arrival_enabled?
end
