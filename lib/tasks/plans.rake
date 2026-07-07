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

  # Planos comerciais — só nome/slug por ora. TODO: preencher features/limits com Planos_Conexi_v2.
  COMMERCIAL_PLANS = [
    { slug: 'start',    name: 'START' },
    { slug: 'standard', name: 'STANDARD' },
    { slug: 'pro',      name: 'PRO' }
  ].freeze

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
      # NÃO seedar features/limits aqui: sem a planilha, nil em limite = ILIMITADO por engano.
      # Preencher plan.plan_features / plan.plan_limits quando Planos_Conexi_v2 for definida.
    end
    puts "[plans:seed] planos comerciais criados (sem valores): #{COMMERCIAL_PLANS.map { |p| p[:slug] }.join(', ')} — preencher com a planilha."
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
