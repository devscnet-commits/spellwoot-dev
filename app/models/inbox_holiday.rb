# frozen_string_literal: true

# == Schema Information
#
# Table name: inbox_holidays
#
#  id            :bigint           not null, primary key
#  holiday_day   :integer          not null
#  holiday_month :integer          not null
#  holiday_year  :integer
#  name          :string           not null
#  recurring     :boolean          default(TRUE), not null
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#  account_id    :bigint
#  inbox_id      :bigint           not null
#
# Indexes
#
#  index_inbox_holidays_on_account_id  (account_id)
#  index_inbox_holidays_on_inbox_id    (inbox_id)
#
# Foreign Keys
#
#  fk_rails_...  (inbox_id => inboxes.id)
#
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
