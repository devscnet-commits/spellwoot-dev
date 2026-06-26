# User-facing Tool. The user configures Tools and the AI executes them; the system resolves
# whether it is an internal capability or an external integration.
class Ai::Tool < ApplicationRecord
  IMPLEMENTATION_TYPES = %w[capability integration].freeze

  belongs_to :account, class_name: '::Account'
  belongs_to :department, class_name: 'Ai::Department', foreign_key: :ai_department_id, optional: true

  validates :implementation_type, inclusion: { in: IMPLEMENTATION_TYPES }

  scope :active, -> { where(status: 'active') }
end
