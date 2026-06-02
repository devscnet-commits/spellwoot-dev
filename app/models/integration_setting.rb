class IntegrationSetting < ApplicationRecord
  belongs_to :account
  validates :provider, presence: true, uniqueness: { scope: :account_id }
  encrypts :config if Chatwoot.encryption_configured?

  def config_hash
    JSON.parse(config.presence || '{}')
  rescue JSON::ParserError
    {}
  end
end
