# frozen_string_literal: true

module UserSchedulable
  extend ActiveSupport::Concern

  # Returns true if the agent is available right now.
  # Priority: agent's own schedule → inbox schedule → always available.
  def working_now?(inbox = nil)
    schedules = agent_schedules
    return check_schedule(schedules) if schedules.exists?
    return !inbox.out_of_office? if inbox.present?

    true
  end

  def default_schedule?
    agent_schedules.none?
  end

  def weekly_agent_schedule
    agent_schedules.order(day_of_week: :asc).as_json(only: AgentSchedule::SCHEDULE_ATTRS)
  end

  def update_agent_schedule(params)
    ActiveRecord::Base.transaction do
      params.each do |slot|
        record = agent_schedules.find_or_initialize_by(day_of_week: slot['day_of_week'])
        record.assign_attributes(slot.slice(*AgentSchedule::SCHEDULE_ATTRS))
        record.account_id ||= account_users.first&.account_id
        record.save!
      end
    end
  end

  private

  def check_schedule(schedules)
    today = schedules.find_by(day_of_week: Time.zone.now.wday)
    return true if today.nil?
    return false if today.closed_all_day?
    return true  if today.open_all_day?

    now = Time.zone.now
    open_time  = now.change(hour: today.open_hour,  min: today.open_minutes)
    close_time = now.change(hour: today.close_hour, min: today.close_minutes)
    now.between?(open_time, close_time)
  end
end
