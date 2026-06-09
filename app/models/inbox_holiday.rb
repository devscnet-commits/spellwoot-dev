# frozen_string_literal: true

class InboxHoliday < ApplicationRecord
  belongs_to :inbox

  before_save :assign_account

  validates :name,          presence: true
  validates :holiday_month, inclusion: { in: 1..12 }
  validates :holiday_day,   inclusion: { in: 1..31 }
  validates :recurring,     inclusion: { in: [true, false] }

  def applies_on?(date = Date.today)
    return false if !recurring && holiday_year.present? && holiday_year != date.year

    date.month == holiday_month && date.day == holiday_day
  end

  private

  def assign_account
    self.account_id = inbox.account_id
  end
end
