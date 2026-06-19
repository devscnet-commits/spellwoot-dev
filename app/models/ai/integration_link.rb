# External connector consumed by Tools with implementation_type=integration.
class Ai::IntegrationLink < ApplicationRecord
  belongs_to :account, class_name: '::Account'
  has_many :tools, class_name: 'Ai::Tool', foreign_key: :integration_link_id

  validates :name, :kind, presence: true
  scope :active, -> { where(status: 'active') }
end
