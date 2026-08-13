# == Schema Information
#
# Table name: operational_flow_reasons
#
#  id                  :bigint           not null, primary key
#  active              :boolean          default(TRUE), not null
#  label               :string           not null
#  position            :integer          default(0), not null
#  result              :integer          not null
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  operational_flow_id :bigint           not null
#  resolution_state_id :bigint
#
# Indexes
#
#  idx_ofr_flow_result_position                           (operational_flow_id,result,position)
#  index_operational_flow_reasons_on_operational_flow_id  (operational_flow_id)
#  index_operational_flow_reasons_on_resolution_state_id  (resolution_state_id)
#
# Foreign Keys
#
#  fk_rails_...  (operational_flow_id => operational_flows.id)
#  fk_rails_...  (resolution_state_id => resolution_states.id)
#
class OperationalFlowReason < ApplicationRecord
  belongs_to :operational_flow
  belongs_to :resolution_state, optional: true

  enum result: { won: 1, lost: 2 }, _prefix: :result

  validates :label, presence: true
  validates :result, presence: true
end
