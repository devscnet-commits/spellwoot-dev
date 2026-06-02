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
      'utm_source'   => 'Meta_Ads',
      'utm_medium'   => referral['media_type'],
      'utm_campaign' => referral['headline'],
      'utm_content'  => referral['source_id'],
      'ctwa_clid'    => referral['ctwa_clid']
    ).compact

    conversation.update!(custom_attributes: custom_attrs)
    track_lead_on_arrival(conversation, custom_attrs)
  end

  def self.track_lead_on_arrival(conversation, custom_attrs)
    if custom_attrs['ctwa_clid'].blank?
      Rails.logger.info "[CAPI] conv=#{conversation.id} lead_job skipped reason=no_ctwa_clid"
      return
    end

    strategy = conversation.account.settings&.dig('meta_conversion_settings', 'strategy')
    unless strategy.nil? || strategy == 'on_arrival'
      Rails.logger.info "[CAPI] conv=#{conversation.id} lead_job skipped reason=strategy=#{strategy}"
      return
    end

    Rails.logger.info "[CAPI] conv=#{conversation.id} lead_job enqueued"
    Meta::TrackLeadJob.perform_later(conversation.id)
  end
  private_class_method :track_lead_on_arrival
end