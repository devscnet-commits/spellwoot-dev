class Meta::HandleCloseEventService
  # Fires a Meta conversion when a human resolves a conversation under a flow that has Meta enabled,
  # using the resolution state the agent picked. The event is fully explicit (never inferred from
  # polarity/category):
  #   - closing_flow.meta_enabled == true
  #   - resolution_state.meta_event_type present (null = never fire)
  #   - the close was a human action
  # event_id is deterministic (canonical_key + conversation) so Meta dedups close→reopen→close.
  def initialize(conversation:, outcome:, user: nil)
    @conversation = conversation
    @outcome = outcome.to_s # canonical_key of the chosen resolution state
    @user = user
  end

  def perform
    return unless @user.is_a?(User)

    flow = @conversation.operational_flow(@user)
    return unless flow&.meta_enabled

    state = flow.state_for(@outcome)
    return if state.nil? || state.meta_event_type.blank?

    Meta::TrackPurchaseJob.perform_later(
      @conversation.id,
      value: sale_value(state),
      event_name: state.meta_event_type,
      event_id: "#{@outcome}-#{@conversation.id}"
    )
  end

  private

  def sale_value(state)
    attr_key = state.meta_value_attr
    return nil if attr_key.blank?

    raw = @conversation.custom_attributes&.dig(attr_key)
    raw.present? ? raw.to_f : nil
  end
end
