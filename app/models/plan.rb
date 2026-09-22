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
  # Chaves de limite numérico geridas por plano. Vivia solta dentro do namespace de rake em
  # lib/tasks/plans.rake (constante que vazava para Object por acidente do escopo léxico); aqui vira
  # fonte única, como MANAGED_FEATURE_KEYS — a tela do Super Admin e o seed leem a MESMA lista.
  MANAGED_LIMIT_KEYS = %w[users inboxes ai_agents crm_pipelines].freeze

  # Ordem dos planos comerciais para decidir se uma troca é upgrade ou downgrade (Plan::ChangeSubscriptionService).
  # courtesy/internal_unlimited ficam de fora — não participam de troca self-service, só atribuição manual.
  # Enterprise saiu: a tabela Planos_Conexi_v2 tem três planos comerciais. Um plano que sobre no banco
  # fora desta lista é apontado por Plan::CatalogAudit ('sem-rank'), não some em silêncio.
  COMMERCIAL_RANK = { 'start' => 1, 'plus' => 2, 'pro_plus' => 3 }.freeze

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

  # --- Grades para a tela do Super Admin -------------------------------------------------------
  # A tela precisa da lista CANÔNICA, não das linhas que por acaso existem no banco: uma PlanFeature
  # ausente já significa "desligada" (#feature_enabled? acima), então mostrar só o que existe deixaria
  # de fora exatamente as features que alguém precisa ligar. Foi assim que `pro`/`standard` chegaram à
  # produção sem nenhuma feature e ninguém teve onde corrigir.
  def feature_grid
    display = SuperAdmin::AccountFeaturesHelper.feature_display_names
    MANAGED_FEATURE_KEYS.index_with do |key|
      { display_name: display[PLAN_FEATURE_TO_ACCOUNT_FLAG[key]].presence || key.humanize,
        enabled: feature_enabled?(key) }
    end
  end

  def limit_grid
    MANAGED_LIMIT_KEYS.index_with do |key|
      limit = limit_for(key)
      { max_value: limit&.max_value,
        overflow_behavior: limit&.overflow_behavior || 'hard_block',
        overage_price_cents: limit&.overage_price_cents }
    end
  end

  # Grava a grade inteira. Chave fora da lista canônica é IGNORADA — a tela não pode inventar feature
  # que o resto do sistema não conhece (PLAN_FEATURE_TO_ACCOUNT_FLAG não saberia para onde mapear).
  def apply_feature_grid!(enabled_keys)
    wanted = Array(enabled_keys).map(&:to_s)
    MANAGED_FEATURE_KEYS.each do |key|
      plan_features.find_or_initialize_by(key: key).update!(enabled: wanted.include?(key))
    end
    reload
  end

  # Preset do plano interno/ilimitado: TODAS as features ligadas (inclusive custom_llm_api_key, que é
  # o que deixa a conta rodar na própria chave pela tela de integrações) e todo limite ilimitado.
  # Mesmo resultado do seed_internal_plan em lib/tasks/plans.rake, disponível pela tela.
  def unlock_everything!
    apply_feature_grid!(MANAGED_FEATURE_KEYS)
    MANAGED_LIMIT_KEYS.each do |key|
      plan_limits.find_or_initialize_by(key: key).update!(max_value: nil, overflow_behavior: 'hard_block')
    end
    reload
  end

  # max_value em BRANCO = ilimitado (nil), que é a convenção vigente do PlanLimit — 0 continua
  # significando "zero permitido" (é assim que um plano bloqueia pipelines hoje). A tabela de planos
  # v2 propõe 0 = ilimitado; enquanto essa divergência não for decidida, a tela mantém a semântica do
  # banco e diz isso no rótulo, para ninguém gravar 0 achando que liberou.
  def apply_limit_grid!(rows)
    rows = (rows || {}).to_h.stringify_keys
    MANAGED_LIMIT_KEYS.each do |key|
      attrs = rows[key].presence or next

      attrs = attrs.to_h.stringify_keys
      behavior = attrs['overflow_behavior'].to_s
      plan_limits.find_or_initialize_by(key: key).update!(
        max_value: attrs['max_value'].to_s.strip.presence&.to_i,
        overflow_behavior: PlanLimit.overflow_behaviors.key?(behavior) ? behavior : 'hard_block',
        overage_price_cents: attrs['overage_price_cents'].to_s.strip.presence&.to_i
      )
    end
    reload
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

  # nil para courtesy/internal_unlimited — não participam da ordem comercial.
  def commercial_rank
    COMMERCIAL_RANK[slug]
  end
end
