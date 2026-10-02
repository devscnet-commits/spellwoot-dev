# Which follow-up behavior applies right now: the one for inside/outside the inbox hours, or a custom
# one whose time windows (HH:MM, inbox timezone) cover the current time. Shared by the AI agent's own
# follow-up (Ai::FollowupConversationJob) and the pipeline stage cadence (Pipelines::AiFollowupRunner).
module Ai::FollowupContext
  private

  # "custom" is more specific and wins over the fixed contexts when both match; ties keep the
  # configured order.
  def active_behavior(behaviors, inbox)
    inside = business_hours_open?(inbox)
    matching = behaviors.select { |behavior| behavior_matches?(behavior, inside, inbox) }
    matching.min_by { |behavior| behavior['context'].to_s == 'custom' ? 0 : 1 }
  end

  def behavior_matches?(behavior, inside, inbox)
    case behavior['context'].to_s
    when 'inbox_hours' then inside
    when 'outside_hours' then !inside
    when 'custom' then within_custom_window?(behavior['windows'], inbox)
    else false
    end
  end

  def business_hours_open?(inbox)
    inbox.respond_to?(:available_now?) ? inbox.available_now? : true
  rescue StandardError
    true
  end

  def within_custom_window?(windows, inbox)
    return false if windows.blank?

    now = current_hm(inbox)
    Array(windows).any? do |window|
      start_at = window['start'].to_s
      end_at = window['end'].to_s
      next false if start_at.blank? || end_at.blank?

      start_at <= end_at ? now.between?(start_at, end_at) : (now >= start_at || now <= end_at)
    end
  end

  def current_hm(inbox)
    tz = inbox.respond_to?(:timezone) ? inbox.timezone : nil
    (tz.present? ? Time.current.in_time_zone(tz) : Time.current).strftime('%H:%M')
  rescue StandardError
    Time.current.strftime('%H:%M')
  end
end
