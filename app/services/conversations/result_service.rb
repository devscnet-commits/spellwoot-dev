class Conversations::ResultService
  class InvalidReasonError < StandardError; end

  # ai_closed is a system outcome with no resolution state; it always clears the business result.
  AI_CLOSED = 'ai_closed'.freeze
  LEGACY_RESULT_BY_OUTCOME = { 'won' => 'won', 'lost' => 'lost', AI_CLOSED => 'none' }.freeze
  # Polarity maps to the native result enum so existing reports keep working regardless of the
  # resolution state's canonical_key (a support "resolved"/positive still aggregates as a win).
  RESULT_BY_POLARITY = { 'positive' => 'won', 'negative' => 'lost', 'neutral' => 'none' }.freeze

  def initialize(conversation:, outcome:, user: nil, reason: nil, ip_address: nil)
    @conversation = conversation
    @outcome = outcome.to_s
    @user = user
    @reason = reason.presence
    @ip_address = ip_address
    @flow = @conversation.operational_flow(user)
    @state = @flow&.state_for(@outcome) unless @outcome == AI_CLOSED
    @result = compute_result
    @recognized = @state.present? || @outcome.in?(LEGACY_RESULT_BY_OUTCOME.keys)
  end

  def perform
    validate_reason!
    previous_result = @conversation.result

    ActiveRecord::Base.transaction do
      @conversation.update!(update_attributes)
      record_event(previous_result)
    end

    @conversation
  end

  private

  def compute_result
    return 'none' if @outcome == AI_CLOSED
    return RESULT_BY_POLARITY.fetch(@state.polarity, 'none') if @state

    LEGACY_RESULT_BY_OUTCOME.fetch(@outcome, 'none')
  end

  def canonical_key
    @state&.canonical_key || @outcome
  end

  def category
    @flow&.category if @state
  end

  def update_attributes
    {
      result: @result,
      result_reason: @reason,
      result_category: category,
      result_canonical_key: (@result == 'none' ? nil : canonical_key),
      result_set_at: Time.current,
      result_set_by_id: @user&.id,
      closed_by_ai: @outcome == AI_CLOSED,
      additional_attributes: synced_attributes
    }
  end

  # Validate the reason (motivo) against the resolution state of the closing flow. A state can
  # require a reason and/or restrict it to a configured list. Skipped when there is no business
  # result or no flow/state.
  def validate_reason!
    return unless @result.in?(%w[won lost])
    return unless @flow

    require_reason = @state ? @state.requires_reason : @flow.require_reason
    raise InvalidReasonError, 'reason_required' if require_reason && @reason.blank?

    valid_labels = reason_labels
    return if valid_labels.empty?

    raise InvalidReasonError, 'reason_invalid' if @reason.present? && valid_labels.exclude?(@reason)
  end

  def reason_labels
    return @state.reasons.where(active: true).pluck(:label) if @state

    @flow.reasons_for(@result).pluck(:label)
  end

  # The canonical result lives in native columns (result / closed_by_ai), but we keep mirroring it
  # into additional_attributes.outcome so external integrations (n8n, CRM, webhooks) that still read
  # the JSON keep working. Retire this only once those consumers migrate to result/closed_by_ai.
  def synced_attributes
    attrs = @conversation.additional_attributes || {}
    if @recognized
      attrs.merge('outcome' => @outcome, 'outcome_set_at' => Time.current.iso8601)
    else
      attrs.except('outcome', 'outcome_set_at')
    end
  end

  def record_event(previous_result)
    @conversation.result_events.create!(
      account_id: @conversation.account_id,
      inbox_id: @conversation.inbox_id,
      team_id: @conversation.team_id,
      user_id: @user&.id,
      result: @result,
      previous_result: previous_result,
      result_category: category,
      result_canonical_key: (@result == 'none' ? nil : canonical_key),
      result_reason: @reason,
      event_type: @recognized ? @outcome : 'cleared',
      ip_address: @ip_address
    )
  end
end
