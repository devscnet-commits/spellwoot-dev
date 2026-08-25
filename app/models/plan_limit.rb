# == Schema Information
#
# Table name: plan_limits
#
#  id                  :bigint           not null, primary key
#  key                 :string           not null
#  max_value           :integer
#  overage_price_cents :integer
#  overflow_behavior   :integer          default("hard_block"), not null
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  plan_id             :bigint           not null
#
# Indexes
#
#  index_plan_limits_on_plan_id          (plan_id)
#  index_plan_limits_on_plan_id_and_key  (plan_id,key) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (plan_id => plans.id)
#
class PlanLimit < ApplicationRecord
  belongs_to :plan

  # hard_block: recusa ao atingir; soft_warning: avisa mas deixa passar; paid_overage: cobra excedente.
  enum overflow_behavior: { hard_block: 0, soft_warning: 1, paid_overage: 2 }

  validates :key, presence: true, uniqueness: { scope: :plan_id }

  # max_value NULL = ilimitado.
  def unlimited?
    max_value.nil?
  end
end
