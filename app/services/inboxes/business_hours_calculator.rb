# frozen_string_literal: true

# Computes how much *working* time elapses between two timestamps for an inbox,
# honoring its configured weekly working hours and timezone. Used to keep SLA
# timers and reporting metrics aligned with business hours.
#
# Returns nil when working hours are disabled or unconfigured so callers can fall
# back to plain wall-clock math.
class Inboxes::BusinessHoursCalculator
  pattr_initialize [:inbox!]

  def elapsed_seconds(from, to)
    config = working_hours_config
    return if config.blank?

    WorkingHours::Config.working_hours = config
    WorkingHours::Config.time_zone = inbox.timezone

    from_in_tz = from.in_time_zone(inbox.timezone).to_time
    to_in_tz   = to.in_time_zone(inbox.timezone).to_time
    from_in_tz.working_time_until(to_in_tz)
  end

  private

  def working_hours_config
    return {} unless inbox.working_hours_enabled?

    inbox.working_hours.each_with_object({}) do |working_hour, config|
      next if working_hour.closed_all_day?

      config[day_key(working_hour.day_of_week)] = {
        format_time(working_hour.open_hour, working_hour.open_minutes) =>
          format_time(working_hour.close_hour, working_hour.close_minutes)
      }
    end
  end

  def day_key(day_of_week)
    %i[sun mon tue wed thu fri sat][day_of_week]
  end

  def format_time(hour, minute)
    format('%<hour>02d:%<min>02d', hour: hour, min: minute)
  end
end
