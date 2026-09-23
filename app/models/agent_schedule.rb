# == Schema Information
#
# Table name: agent_schedules
#
#  id             :bigint           not null, primary key
#  close_hour     :integer
#  close_minutes  :integer
#  closed_all_day :boolean          default(FALSE), not null
#  day_of_week    :integer          not null
#  open_all_day   :boolean          default(FALSE), not null
#  open_hour      :integer
#  open_minutes   :integer
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#  account_id     :bigint           not null
#  user_id        :bigint           not null
#
# Indexes
#
#  index_agent_schedules_on_account_id               (account_id)
#  index_agent_schedules_on_user_id                  (user_id)
#  index_agent_schedules_on_user_id_and_day_of_week  (user_id,day_of_week) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#  fk_rails_...  (user_id => users.id)
#
class AgentSchedule < ApplicationRecord
  belongs_to :user
  belongs_to :account

  before_validation :ensure_open_all_day_hours

  validates :day_of_week, inclusion: { in: 0..6 }
  validates :open_hour,     presence: true, unless: :closed_all_day?
  validates :open_minutes,  presence: true, unless: :closed_all_day?
  validates :close_hour,    presence: true, unless: :closed_all_day?
  validates :close_minutes, presence: true, unless: :closed_all_day?
  validates :open_hour,     inclusion: { in: 0..23 }, unless: :closed_all_day?
  validates :close_hour,    inclusion: { in: 0..23 }, unless: :closed_all_day?
  validates :open_minutes,  inclusion: { in: 0..59 }, unless: :closed_all_day?
  validates :close_minutes, inclusion: { in: 0..59 }, unless: :closed_all_day?
  validate :close_after_open, unless: :closed_all_day?

  SCHEDULE_ATTRS = %w[day_of_week closed_all_day open_hour open_minutes close_hour close_minutes open_all_day].freeze

  private

  def ensure_open_all_day_hours
    return unless open_all_day?

    self.open_hour    = 0
    self.open_minutes = 0
    self.close_hour   = 23
    self.close_minutes = 59
  end

  def close_after_open
    return unless open_hour.present? && close_hour.present?
    return unless open_hour.hours + open_minutes.to_i.minutes >= close_hour.hours + close_minutes.to_i.minutes

    errors.add(:close_hour, 'Closing time cannot be before opening time')
  end
end
