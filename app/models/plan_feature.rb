# == Schema Information
#
# Table name: plan_features
#
#  id         :bigint           not null, primary key
#  enabled    :boolean          default(FALSE), not null
#  key        :string           not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  plan_id    :bigint           not null
#
# Indexes
#
#  index_plan_features_on_plan_id          (plan_id)
#  index_plan_features_on_plan_id_and_key  (plan_id,key) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (plan_id => plans.id)
#
class PlanFeature < ApplicationRecord
  belongs_to :plan

  validates :key, presence: true, uniqueness: { scope: :plan_id }
end
