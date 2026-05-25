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
        media_url: referral['source_url'],
        ad_body: referral['body'],
        captured_at: Time.current
      }.compact
    }

    conversation.update!(
      additional_attributes:
        (conversation.additional_attributes || {})
          .deep_merge(attribution_payload)
    )
  end
end
