# == Schema Information
#
# Table name: plans
#
#  id         :bigint           not null, primary key
#  active     :boolean          default(TRUE), not null
#  name       :string           not null
#  slug       :string           not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#
# Indexes
#
#  index_plans_on_slug  (slug) UNIQUE
#
class Plan < ApplicationRecord
  has_many :plan_features, dependent: :destroy
  has_many :plan_limits, dependent: :destroy
  has_many :subscriptions, dependent: :restrict_with_exception

  validates :name, presence: true
  validates :slug, presence: true, uniqueness: true

  scope :active, -> { where(active: true) }

  def feature_enabled?(key)
    plan_features.find { |f| f.key == key.to_s }&.enabled || false
  end

  def limit_for(key)
    plan_limits.find { |l| l.key == key.to_s }
  end
end
