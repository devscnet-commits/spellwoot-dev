# frozen_string_literal: true

# == Schema Information
#
# Table name: working_periods
#
#  id            :bigint           not null, primary key
#  day_of_week   :integer          not null
#  end_hour      :integer          not null
#  end_minutes   :integer          default(0), not null
#  position      :integer          default(0), not null
#  start_hour    :integer          not null
#  start_minutes :integer          default(0), not null
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#  account_id    :bigint
#  inbox_id      :bigint           not null
#
# Indexes
#
#  index_working_periods_on_account_id                (account_id)
#  index_working_periods_on_inbox_id                  (inbox_id)
#  index_working_periods_on_inbox_id_and_day_of_week  (inbox_id,day_of_week)
#
# Foreign Keys
#
#  fk_rails_...  (inbox_id => inboxes.id)
#
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
