# == Schema Information
#
# Table name: provider_instances
#
#  id            :bigint           not null, primary key
#  instance_name :string           not null
#  phone_number  :string
#  provider      :string           not null
#  raw_data      :jsonb
#  status        :string           default("unknown")
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#  account_id    :bigint           not null
#  instance_id   :string
#
# Indexes
#
#  idx_provider_instances_unique                        (account_id,provider,instance_name) UNIQUE
#  index_provider_instances_on_account_id               (account_id)
#  index_provider_instances_on_account_id_and_provider  (account_id,provider)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#
class ProviderInstance < ApplicationRecord
  belongs_to :account

  validates :provider, presence: true
  validates :instance_name, presence: true
  validates :instance_name, uniqueness: { scope: %i[account_id provider] }

  def instance_token
    raw_data['token'] || raw_data['instanceToken']
  end
end
