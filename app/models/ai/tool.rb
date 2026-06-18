# User-facing Tool. The user configures Tools and the AI executes them; the system resolves
# whether it is an internal capability or an external integration.
class Ai::Tool < ApplicationRecord
  IMPLEMENTATION_TYPES = %w[capability integration].freeze
  GOVERNANCE = %w[allowed require_confirmation require_approval].freeze

  belongs_to :account, class_name: '::Account'
  belongs_to :department, class_name: 'Ai::Department', foreign_key: :ai_department_id, optional: true

  validates :implementation_type, inclusion: { in: IMPLEMENTATION_TYPES }
  validates :governance, inclusion: { in: GOVERNANCE }

  scope :active, -> { where(status: 'active') }
end
