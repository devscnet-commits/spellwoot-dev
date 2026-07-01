# == Schema Information
#
# Table name: integration_settings
#
#  id         :bigint           not null, primary key
#  config     :text
#  enabled    :boolean          default(TRUE), not null
#  provider   :string           not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  account_id :bigint
#
# Indexes
#
#  index_integration_settings_global_provider             (provider) UNIQUE WHERE (account_id IS NULL)
#  index_integration_settings_on_account_id_and_provider  (account_id,provider) UNIQUE WHERE (account_id IS NOT NULL)
#
# Foreign Keys
#
#  fk_rails_...  (account_id => accounts.id)
#
class IntegrationSetting < ApplicationRecord
  belongs_to :account, optional: true  # nil = global/system-level setting

  validates :provider, presence: true
  validate :uniqueness_per_scope

  encrypts :config if Chatwoot.encryption_configured?

  scope :global, -> { where(account_id: nil) }
  scope :for_account, ->(account_id) { where(account_id: account_id) }

  def config_hash
    JSON.parse(config.presence || '{}')
  rescue JSON::ParserError
    {}
  end

  private

  def uniqueness_per_scope
    scope = self.class.where(provider: provider)
    scope = account_id ? scope.where(account_id: account_id) : scope.global
    scope = scope.where.not(id: id) if persisted?
    errors.add(:provider, :taken) if scope.exists?
  end
end
