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
