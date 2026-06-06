class Conversations::ResultService
  # Business outcomes that map to a first-class result. Anything else clears the result.
  OUTCOMES = %w[won lost ai_closed].freeze
  RESULT_BY_OUTCOME = { 'won' => 'won', 'lost' => 'lost', 'ai_closed' => 'none' }.freeze

  def initialize(conversation:, outcome:, user: nil, reason: nil, ip_address: nil)
    @conversation = conversation
    @outcome = outcome.to_s
    @recognized = @outcome.in?(OUTCOMES)
    @result = RESULT_BY_OUTCOME.fetch(@outcome, 'none')
    @user = user
    @reason = reason.presence
    @ip_address = ip_address
  end

  def perform
    previous_result = @conversation.result

    ActiveRecord::Base.transaction do
      @conversation.update!(
        result: @result,
        result_reason: @reason,
        result_set_at: Time.current,
        result_set_by_id: @user&.id,
        additional_attributes: synced_attributes
      )
      record_event(previous_result)
    end

    @conversation
  end

  private

  # Keep additional_attributes.outcome in sync so every existing reader (reports, Meta,
  # required attributes, serializers) keeps working unchanged during the transition.
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
      result_reason: @reason,
      event_type: @recognized ? @outcome : 'cleared',
      ip_address: @ip_address
    )
  end
end
