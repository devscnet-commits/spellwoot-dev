class Meta::HandleCloseEventService
  # Called when an agent marks a conversation as Won or Lost (on_close strategy).
  # Fires Purchase for "won", nothing for "lost" (no conversion to report).
  # Idempotent: the ConversionsApiService checks already_sent? before posting.
  def initialize(conversation:, outcome:)
    @conversation = conversation
    @outcome = outcome # :won | :lost
    @account = conversation.account
  end

  def perform
    return unless on_close_strategy?

    return unless @outcome == :won

    value = sale_value
    Meta::TrackPurchaseJob.perform_later(@conversation.id, value: value)
  end

  private

  def on_close_strategy?
    @account.settings&.dig('meta_conversion_settings', 'strategy') == 'on_close'
  end

  def sale_value
    value_field = @account.settings&.dig('meta_conversion_settings', 'value_field')
    return nil if value_field.blank?

    raw = @conversation.custom_attributes&.dig(value_field)
    raw.present? ? raw.to_f : nil
  end
end
