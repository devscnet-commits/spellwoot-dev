# frozen_string_literal: true

class WorkingPeriod < ApplicationRecord
  belongs_to :inbox

  before_save :assign_account

  validates :day_of_week,    inclusion: { in: 0..6 }
  validates :start_hour,     inclusion: { in: 0..23 }
  validates :end_hour,       inclusion: { in: 0..23 }
  validates :start_minutes,  inclusion: { in: 0..59 }
  validates :end_minutes,    inclusion: { in: 0..59 }
  validate  :end_after_start

  default_scope { order(:day_of_week, :position, :start_hour, :start_minutes) }

  private

  def assign_account
    self.account_id = inbox.account_id
  end

  def end_after_start
    return if start_hour.nil? || end_hour.nil?

    start_total = start_hour * 60 + start_minutes.to_i
    end_total   = end_hour   * 60 + end_minutes.to_i
    errors.add(:end_hour, 'must be after start') if end_total <= start_total
  end
end
