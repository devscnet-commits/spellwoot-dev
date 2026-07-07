# Seed idempotente do scaffolding de planos (Fase 1). Rodar manualmente:
#   rails plans:seed
#
# Cria: o plano interno "ilimitado" (todas as features on, todos os limites nil), os planos
# comerciais START/STANDARD/PRO (SEM valores — preencher com Planos_Conexi_v2) e aponta as 3 contas
# do grupo para o plano interno, para NÃO serem afetadas pelo rollout.
namespace :plans do
  # Chaves canônicas de feature vêm de Plan::MANAGED_FEATURE_KEYS (fonte única, também usada pela
  # ponte Plano->conta). Referenciadas em RUNTIME dentro das tasks (sob :environment); não no corpo
  # do namespace, para não acoplar o parse do rake ao autoload do model.
  LIMIT_KEYS = %w[users inboxes ai_agents crm_pipelines].freeze

  INTERNAL_SLUG = 'internal_unlimited'.freeze
  # Contas do grupo que recebem o plano interno (match por nome, case-insensitive).
  INTERNAL_ACCOUNT_NAMES = ['Athena', 'SCNET', 'Vale Mais Net'].freeze

  # Planos comerciais (Planos_Conexi_v2, Fase 1.1). `features` lista SÓ as features ligadas (as
  # demais de FEATURE_KEYS entram como enabled=false). `limits` = max_value por chave (0 = zero
  # permitido; NUNCA nil aqui — nil seria "ilimitado"). overflow_behavior: hard_block em todos.
  # SEM preços (não há campo no schema) e SEM overage (manter hard_block até confirmação de valores).
  COMMERCIAL_PLANS = [
    {
      slug: 'start', name: 'START',
      features: %w[], # nenhuma feature ligada no START
      limits: { 'users' => 3, 'inboxes' => 2, 'ai_agents' => 2, 'crm_pipelines' => 0 }
    },
    {
      slug: 'standard', name: 'STANDARD',
      features: %w[
        webchat_channel facebook_channel ai_copilot dashboards_bi conversion_api webhook_api
        sla_tracking crm_kanban crm_automations message_scheduling custom_llm_api_key
      ], # off no STANDARD: erp_integration, isp_ready_flows, audit_logs, account_manager
      limits: { 'users' => 10, 'inboxes' => 8, 'ai_agents' => 5, 'crm_pipelines' => 3 }
    },
    {
      slug: 'pro', name: 'PRO',
      features: :all, # todas as MANAGED_FEATURE_KEYS ligadas no PRO (expandido em runtime)
      limits: { 'users' => 30, 'inboxes' => 20, 'ai_agents' => 10, 'crm_pipelines' => 10 }
    }
  ].freeze

  # Referência de créditos de IA por plano (AiCreditBalance.plan_credits, renovados no ciclo):
  # START=500, STANDARD=1000, PRO=1000. NÃO seedado aqui — a renovação de plan_credits é fase futura.
  #
  # Nota overage: 'users' no PRO ("Atendente adicional") pode virar overflow_behavior: :paid_overage
  # + overage_price_cents no futuro. Mantido hard_block até haver preço oficial confirmado.

  desc 'Seed idempotente de planos + assinatura interna das 3 contas do grupo'
  task seed: :environment do
    seed_internal_plan
    seed_commercial_plans
    assign_internal_accounts
    puts '[plans:seed] concluído.'
  end

  def seed_internal_plan
    feature_keys = Plan::MANAGED_FEATURE_KEYS
    plan = Plan.find_or_initialize_by(slug: INTERNAL_SLUG)
    plan.update!(name: 'Interno (ilimitado)', active: true)
    feature_keys.each do |key|
      feature = plan.plan_features.find_or_initialize_by(key: key)
      feature.update!(enabled: true)
    end
    LIMIT_KEYS.each do |key|
      limit = plan.plan_limits.find_or_initialize_by(key: key)
      limit.update!(max_value: nil, overflow_behavior: :hard_block) # nil = ilimitado
    end
    puts "[plans:seed] plano interno '#{INTERNAL_SLUG}': #{feature_keys.size} features on, #{LIMIT_KEYS.size} limites ilimitados."
  end

  def seed_commercial_plans
    feature_keys = Plan::MANAGED_FEATURE_KEYS
    COMMERCIAL_PLANS.each do |attrs|
      plan = Plan.find_or_initialize_by(slug: attrs[:slug])
      plan.update!(name: attrs[:name], active: true)

      enabled = attrs[:features] == :all ? feature_keys : attrs[:features]

      # Grade completa de features (todas as MANAGED_FEATURE_KEYS): ligada se estiver em `enabled`.
      feature_keys.each do |key|
        feature = plan.plan_features.find_or_initialize_by(key: key)
        feature.update!(enabled: enabled.include?(key))
      end

      # Limites numéricos por chave. hard_block em todos (sem overage nesta fase).
      attrs[:limits].each do |key, max_value|
        limit = plan.plan_limits.find_or_initialize_by(key: key)
        limit.update!(max_value: max_value, overflow_behavior: :hard_block)
      end

      puts "[plans:seed] plano '#{attrs[:slug]}': #{enabled.size}/#{feature_keys.size} features on, limites #{attrs[:limits]}."
    end
  end

  def assign_internal_accounts
    internal = Plan.find_by(slug: INTERNAL_SLUG)
    INTERNAL_ACCOUNT_NAMES.each do |name|
      accounts = Account.where('LOWER(name) = ?', name.downcase)
      if accounts.empty?
        warn "[plans:seed] AVISO: conta '#{name}' não encontrada — pulando."
        next
      end
      accounts.each do |account|
        sub = account.subscriptions.find_or_initialize_by(plan: internal, status: Subscription.statuses[:active])
        sub.started_at ||= Time.current
        sub.save!
        # Ponte explícita: em re-run idempotente, sub.save! sem mudanças NÃO dispara o after_save,
        # então sincronizamos as feature flags da conta aqui para refletir sempre o plano interno.
        internal.sync_features_to!(account)
        puts "[plans:seed] conta ##{account.id} (#{account.name}) -> assinatura interna ativa + features sincronizadas."
      end
    end
  end
end
