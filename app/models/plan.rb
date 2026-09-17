# == Schema Information
#
# Table name: plans
#
#  id                            :bigint           not null, primary key
#  active                        :boolean          default(TRUE), not null
#  ai_credit_overage_price_cents :integer
#  ai_credits_included           :integer          default(0), not null
#  annual_price_cents            :integer
#  courtesy                      :boolean          default(FALSE), not null
#  description                   :text
#  monthly_price_cents           :integer
#  name                          :string           not null
#  promo_months_count            :integer
#  promo_price_cents             :integer
#  setup_fee_cents               :integer
#  slug                          :string           not null
#  visible_to_new_subscribers    :boolean          default(TRUE), not null
#  created_at                    :datetime         not null
#  updated_at                    :datetime         not null
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
    # ai_copilot reaproveita captain_tasks (rewrite/resumo/sugestão de resposta) — já existe e era
    # grátis por padrão; decidido na Fase 0 restringir por plano em vez de criar chave nova.
    'ai_copilot' => 'captain_tasks',
    'conversion_api' => 'conversion_api',
    'webhook_api' => 'webhook_api',
    'custom_llm_api_key' => 'custom_llm_api_key',
    'crm_kanban' => 'crm_kanban',
    'crm_automations' => 'crm_automations',
    'erp_integration' => 'erp_integration',
    'isp_ready_flows' => 'isp_ready_flows',
    'message_scheduling' => 'message_scheduling',
    'account_manager' => 'account_manager',
    'api_user_token' => 'api_user_token'
  }.freeze
  # channel_whatsapp e channel_api NÃO entram aqui: são X em todos os 4 planos comerciais (não variam
  # por plano, ver Planos_Conexi_v2) — ficam enabled: true por padrão em config/features.yml, mesmo
  # tratamento de channel_instagram/channel_email hoje.
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

  # Leitura opcional do preço em reais a partir dos *_cents (fonte da verdade). nil = não definido.
  def monthly_price
    monthly_price_cents && monthly_price_cents / 100.0
  end

  def setup_fee
    setup_fee_cents && setup_fee_cents / 100.0
  end

  def annual_price
    annual_price_cents && annual_price_cents / 100.0
  end

  def promo_price
    promo_price_cents && promo_price_cents / 100.0
  end

  def ai_credit_overage_price
    ai_credit_overage_price_cents && ai_credit_overage_price_cents / 100.0
  end
end
