# frozen_string_literal: true

module OutOfOffisable
  extend ActiveSupport::Concern

  # Legacy single-period attrs (kept for backward compat)
  OFFISABLE_ATTRS = %w[
    day_of_week closed_all_day open_hour open_minutes close_hour close_minutes open_all_day
    has_lunch_break lunch_start_hour lunch_start_minutes lunch_end_hour lunch_end_minutes
  ].freeze

  PERIOD_ATTRS  = %w[day_of_week start_hour start_minutes end_hour end_minutes position].freeze
  HOLIDAY_ATTRS = %w[name holiday_month holiday_day holiday_year recurring].freeze

  included do
    has_many :working_hours,  dependent: :destroy_async
    has_many :working_periods, dependent: :destroy_async
    has_many :inbox_holidays,  dependent: :destroy_async
    after_create :create_default_working_hours
  end

  # ── Primary availability check ──────────────────────────────────────────────

  def available_now?
    return true unless working_hours_enabled?
    return false if holiday_today?

    # Use multi-period schedule if configured, otherwise fall back to legacy
    working_periods.exists? ? periods_open_now? : !working_hours.today&.closed_now?
  rescue StandardError => e
    # Availability must never be blocked by a failure in the holidays/periods module.
    Rails.logger.error "[BusinessHours] available_now? failed for inbox #{id}: #{e.message}"
    true
  end

  def out_of_office?
    !available_now?
  end

  def working_now?
    available_now?
  end

  # ── Status ───────────────────────────────────────────────────────────────────

  # Returns a hash describing the current operational state:
  #   { status: :open | :interval | :closed | :holiday | :disabled,
  #     until:     Time (when open, when the period ends),
  #     next_open: Time (when closed/interval, when next period starts) }
  def current_status
    return { status: :disabled } unless working_hours_enabled?
    return { status: :holiday }  if holiday_today?

    now     = Time.zone.now.in_time_zone(timezone)
    periods = today_working_periods_in_tz(now)

    if periods.any?
      # Inside an open period?
      periods.each do |p|
        if now.between?(p[:start], p[:end])
          # Find next closing: end of this period
          next_close = p[:end]
          return { status: :open, until: next_close }
        end
      end

      # Between periods (interval)?
      next_period = periods.find { |p| p[:start] > now }
      if next_period
        return { status: :interval, next_open: next_period[:start] }
      end
    end

    # Closed for the rest of today — find next open slot
    { status: :closed, next_open: next_available_time(now) }
  rescue StandardError => e
    # The status badge is non-essential — never let it 500 the inbox payload.
    Rails.logger.error "[BusinessHours] current_status failed for inbox #{id}: #{e.message}"
    { status: :disabled }
  end

  def next_available_time(from = Time.zone.now.in_time_zone(timezone))
    7.times.each do |offset|
      check_time = from + (offset + 1).days
      day        = check_time.wday
      day_periods = working_periods.where(day_of_week: day)
      next if day_periods.none?

      first = day_periods.first
      return check_time.change(hour: first.start_hour, min: first.start_minutes)
    end
    nil
  end

  def holiday_today?
    today = Time.zone.now.in_time_zone(timezone).to_date
    inbox_holidays.any? { |h| h.applies_on?(today) }
  end

  # ── Schedule accessors ───────────────────────────────────────────────────────

  # The three schedule accessors below feed the inbox JSON payload. They must
  # degrade to an empty list (never raise) so the Business Hours tab keeps
  # rendering even if the holidays/periods module or its tables are unavailable.
  def working_periods_schedule
    working_periods.as_json(only: PERIOD_ATTRS + ['id'])
  rescue StandardError => e
    Rails.logger.error "[BusinessHours] working_periods_schedule failed for inbox #{id}: #{e.message}"
    []
  end

  def holidays_schedule
    inbox_holidays.as_json(only: HOLIDAY_ATTRS + ['id'])
  rescue StandardError => e
    Rails.logger.error "[BusinessHours] holidays_schedule failed for inbox #{id}: #{e.message}"
    []
  end

  # Legacy — kept for old code paths and widget
  def weekly_schedule
    working_hours.order(day_of_week: :asc).select(*OFFISABLE_ATTRS).as_json(except: :id)
  rescue StandardError => e
    Rails.logger.error "[BusinessHours] weekly_schedule failed for inbox #{id}: #{e.message}"
    []
  end

  # ── Writers ──────────────────────────────────────────────────────────────────

  def update_working_periods(params)
    return if params.blank?

    ActiveRecord::Base.transaction do
      # Replace all periods for the submitted days
      submitted_days = params.map { |p| p['day_of_week'].to_i }.uniq
      working_periods.where(day_of_week: submitted_days).delete_all

      params.each_with_index do |period, idx|
        working_periods.create!(period.slice(*PERIOD_ATTRS).merge('position' => idx))
      end
    end
  end

  def update_holidays(params)
    return if params.blank?

    ActiveRecord::Base.transaction do
      # Full replacement — client sends the whole list
      inbox_holidays.delete_all
      params.each do |holiday|
        inbox_holidays.create!(holiday.slice(*HOLIDAY_ATTRS))
      end
    end
  end

  # Legacy single-period writer
  def update_working_hours(params)
    return if params.blank?

    ActiveRecord::Base.transaction do
      params.each do |working_hour|
        record = working_hours.find_by(day_of_week: working_hour['day_of_week'])
        if record
          record.update(working_hour.slice(*OFFISABLE_ATTRS))
        else
          Rails.logger.warn "[WorkingHours] No record found for inbox #{id}, day_of_week=#{working_hour['day_of_week']}"
        end
      end
    end
  end

  private

  def periods_open_now?
    now = Time.zone.now.in_time_zone(timezone)
    today_working_periods_in_tz(now).any? { |p| now.between?(p[:start], p[:end]) }
  end

  def today_working_periods_in_tz(now)
    working_periods.where(day_of_week: now.wday).map do |p|
      {
        start: now.change(hour: p.start_hour, min: p.start_minutes),
        end:   now.change(hour: p.end_hour,   min: p.end_minutes)
      }
    end
  end

  def create_default_working_hours
    working_hours.create!(day_of_week: 0, closed_all_day: true, open_all_day: false)
    working_hours.create!(day_of_week: 1, open_hour: 9, open_minutes: 0, close_hour: 17, close_minutes: 0, open_all_day: false)
    working_hours.create!(day_of_week: 2, open_hour: 9, open_minutes: 0, close_hour: 17, close_minutes: 0, open_all_day: false)
    working_hours.create!(day_of_week: 3, open_hour: 9, open_minutes: 0, close_hour: 17, close_minutes: 0, open_all_day: false)
    working_hours.create!(day_of_week: 4, open_hour: 9, open_minutes: 0, close_hour: 17, close_minutes: 0, open_all_day: false)
    working_hours.create!(day_of_week: 5, open_hour: 9, open_minutes: 0, close_hour: 17, close_minutes: 0, open_all_day: false)
    working_hours.create!(day_of_week: 6, closed_all_day: true, open_all_day: false)
  end
end
