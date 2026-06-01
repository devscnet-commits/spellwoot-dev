class Attribution::ConversationAttributionService
  def self.process(conversation:, referral:, provider: 'meta')
    return if conversation.blank?
    return if referral.blank?

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
    return if custom_attrs['ctwa_clid'].blank?

    strategy = conversation.account.settings&.dig('meta_conversion_settings', 'strategy')
    # Default to on_arrival when no strategy is configured (backward-compat)
    return unless strategy.nil? || strategy == 'on_arrival'

    Meta::TrackLeadJob.perform_later(conversation.id)
  end
  private_class_method :track_lead_on_arrival
end
