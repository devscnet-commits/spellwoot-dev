# User-facing Tool. The user configures Tools and the AI executes them; the system resolves
# whether it is an internal capability or an external integration.
# == Schema Information
#
# Table name: ai_tools
#
#  id                  :bigint           not null, primary key
#  capability_key      :string
#  description         :text
#  implementation_type :string           default("capability"), not null
#  input_schema        :jsonb            not null
#  name                :string           not null
#  output_schema       :jsonb            not null
#  status              :string           default("active"), not null
#  webhook_config      :jsonb            not null
#  created_at          :datetime         not null
#  updated_at          :datetime         not null
#  account_id          :bigint           not null
#  ai_department_id    :bigint
#  integration_link_id :bigint
#
# Indexes
#
#  index_ai_tools_on_ai_department_id  (ai_department_id)
#
class Ai::Tool < ApplicationRecord
  IMPLEMENTATION_TYPES = %w[capability integration webhook].freeze

  belongs_to :account, class_name: '::Account'
  belongs_to :department, class_name: 'Ai::Department', foreign_key: :ai_department_id, optional: true

  validates :implementation_type, inclusion: { in: IMPLEMENTATION_TYPES }

  scope :active, -> { where(status: 'active') }
end
