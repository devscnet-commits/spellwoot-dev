# frozen_string_literal: true

class InboxException < ApplicationRecord
  belongs_to :inbox

  before_save :assign_account

  validates :exception_date, presence: true

  default_scope { order(:exception_date) }

  def applies_on?(date = Date.today)
    exception_date == date
  end

  private

  def assign_account
    self.account_id = inbox.account_id
  end
end
