# External connector consumed by Tools with implementation_type=integration.
# == Schema Information
#
# Table name: ai_integration_links
#
#  id               :bigint           not null, primary key
#  auth             :jsonb            not null
#  cost             :decimal(12, 6)   default(0.0), not null
#  endpoint         :string
#  headers          :jsonb            not null
#  http_method      :string           default("POST"), not null
#  kind             :string           default("webhook"), not null
#  name             :string           not null
#  payload_template :jsonb            not null
#  retry_count      :integer          default(0), not null
#  status           :string           default("active"), not null
#  timeout_seconds  :integer          default(10), not null
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  account_id       :bigint           not null
#
# Indexes
#
#  index_ai_integration_links_on_account_id  (account_id)
#
class Ai::IntegrationLink < ApplicationRecord
  belongs_to :account, class_name: '::Account'
  has_many :tools, class_name: 'Ai::Tool', foreign_key: :integration_link_id

  validates :name, :kind, presence: true
  scope :active, -> { where(status: 'active') }
end
