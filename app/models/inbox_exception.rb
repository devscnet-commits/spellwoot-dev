# frozen_string_literal: true

# == Schema Information
#
# Table name: inbox_exceptions
#
#  id             :bigint           not null, primary key
#  closed         :boolean          default(FALSE), not null
#  exception_date :date             not null
#  name           :string
#  periods        :jsonb            not null
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#  account_id     :bigint
#  inbox_id       :bigint           not null
#
# Indexes
#
#  index_inbox_exceptions_on_account_id  (account_id)
#  index_inbox_exceptions_on_inbox_id    (inbox_id)
#
# Foreign Keys
#
#  fk_rails_...  (inbox_id => inboxes.id)
#
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
