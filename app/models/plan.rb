# == Schema Information
#
# Table name: plans
#
#  id         :bigint           not null, primary key
#  active     :boolean          default(TRUE), not null
#  name       :string           not null
#  slug       :string           not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#
# Indexes
#
#  index_plans_on_slug  (slug) UNIQUE
#
class Plan < ApplicationRecord
  # Ponte Plano -> feature flags de conta (Featurable). Cada PlanFeature.key é mapeada para a chave
  # de feature de conta (config/features.yml) que já gateia a UI/rota. Onde o Chatwoot já tinha
  # gating, reusamos a chave EXISTENTE (channel_website, channel_facebook, reports, sla, audit_logs);
  # as demais são chaves novas (enforcement futuro, quando o módulo existir).
  PLAN_FEATURE_TO_ACCOUNT_FLAG = {
    'webchat_channel' => 'channel_website',
    'facebook_channel' => 'channel_facebook',
    'dashboards_bi' => 'reports',
    'sla_tracking' => 'sla',
    'audit_logs' => 'audit_logs',
    'ai_copilot' => 'ai_copilot',
    'conversion_api' => 'conversion_api',
    'webhook_api' => 'webhook_api',
    'custom_llm_api_key' => 'custom_llm_api_key',
    'crm_kanban' => 'crm_kanban',
    'crm_automations' => 'crm_automations',
    'erp_integration' => 'erp_integration',
    'isp_ready_flows' => 'isp_ready_flows',
    'message_scheduling' => 'message_scheduling',
    'account_manager' => 'account_manager'
  }.freeze
  MANAGED_FEATURE_KEYS = PLAN_FEATURE_TO_ACCOUNT_FLAG.keys.freeze

  has_many :plan_features, dependent: :destroy
  has_many :plan_limits, dependent: :destroy
  has_many :subscriptions, dependent: :restrict_with_exception

  validates :name, presence: true
  validates :slug, presence: true, uniqueness: true

  scope :active, -> { where(active: true) }

  # Reflete as PlanFeature deste plano no account.enabled_feature_keys (Featurable), tocando SÓ as
  # chaves gerenciadas pelo plano — não mexe em features base da conta. Assim todo o gating existente
  # (sidebar, rotas meta.featureFlag, account.feature_enabled?) passa a refletir o plano.
  def sync_features_to!(account)
    enabled_keys = plan_features.select(&:enabled).map(&:key)
    on_flags  = MANAGED_FEATURE_KEYS.select { |k| enabled_keys.include?(k) }.map { |k| PLAN_FEATURE_TO_ACCOUNT_FLAG[k] }
    off_flags = MANAGED_FEATURE_KEYS.reject { |k| enabled_keys.include?(k) }.map { |k| PLAN_FEATURE_TO_ACCOUNT_FLAG[k] }
    account.enable_features(*on_flags) if on_flags.any?
    account.disable_features(*off_flags) if off_flags.any?
    account.save!
  end

  def feature_enabled?(key)
    plan_features.find { |f| f.key == key.to_s }&.enabled || false
  end

  def limit_for(key)
    plan_limits.find { |l| l.key == key.to_s }
  end
end
