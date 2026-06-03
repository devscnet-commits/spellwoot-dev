class ProviderInstance < ApplicationRecord
  belongs_to :account

  validates :provider, presence: true
  validates :instance_name, presence: true
  validates :instance_name, uniqueness: { scope: %i[account_id provider] }

  def instance_token
    raw_data['token'] || raw_data['instanceToken']
  end
end
