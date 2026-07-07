# Seed idempotente do scaffolding de planos (Fase 1). Rodar manualmente:
#   rails plans:seed
#
# Cria: o plano interno "ilimitado" (todas as features on, todos os limites nil), os planos
# comerciais START/STANDARD/PRO (SEM valores — preencher com Planos_Conexi_v2) e aponta as 3 contas
# do grupo para o plano interno, para NÃO serem afetadas pelo rollout.
namespace :plans do
  # Chaves canônicas (espelham a spec). Os VALORES por plano comercial vêm da planilha.
  FEATURE_KEYS = %w[
    webchat_channel facebook_channel ai_copilot erp_integration isp_ready_flows dashboards_bi
    conversion_api webhook_api sla_tracking audit_logs crm_kanban crm_automations
    message_scheduling account_manager custom_llm_api_key
  ].freeze
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
      features: FEATURE_KEYS, # todas ligadas no PRO
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
    plan = Plan.find_or_initialize_by(slug: INTERNAL_SLUG)
    plan.update!(name: 'Interno (ilimitado)', active: true)
    FEATURE_KEYS.each do |key|
      feature = plan.plan_features.find_or_initialize_by(key: key)
      feature.update!(enabled: true)
    end
    LIMIT_KEYS.each do |key|
      limit = plan.plan_limits.find_or_initialize_by(key: key)
      limit.update!(max_value: nil, overflow_behavior: :hard_block) # nil = ilimitado
    end
    puts "[plans:seed] plano interno '#{INTERNAL_SLUG}': #{FEATURE_KEYS.size} features on, #{LIMIT_KEYS.size} limites ilimitados."
  end

  def seed_commercial_plans
    COMMERCIAL_PLANS.each do |attrs|
      plan = Plan.find_or_initialize_by(slug: attrs[:slug])
      plan.update!(name: attrs[:name], active: true)

      # Grade completa de features (todas as FEATURE_KEYS): ligada se estiver em attrs[:features].
      FEATURE_KEYS.each do |key|
        feature = plan.plan_features.find_or_initialize_by(key: key)
        feature.update!(enabled: attrs[:features].include?(key))
      end

      # Limites numéricos por chave. hard_block em todos (sem overage nesta fase).
      attrs[:limits].each do |key, max_value|
        limit = plan.plan_limits.find_or_initialize_by(key: key)
        limit.update!(max_value: max_value, overflow_behavior: :hard_block)
      end

      puts "[plans:seed] plano '#{attrs[:slug]}': #{attrs[:features].size}/#{FEATURE_KEYS.size} features on, limites #{attrs[:limits]}."
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
        puts "[plans:seed] conta ##{account.id} (#{account.name}) -> assinatura interna ativa."
      end
    end
  end
end
