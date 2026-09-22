# Seed idempotente dos planos comerciais (Fase 1). Rodar manualmente:
#   rails plans:seed
#
# Cria: o plano interno "ilimitado" (uso do grupo — Athena/SCNET/Vale Mais Net, não é oferta
# comercial), os 4 planos comerciais START/PLUS/PRO+/Enterprise e o plano Cortesia (parceiros/
# indicadores — setado manualmente, nunca por self-service). Dados conferidos com Planos_Conexi_v2.
namespace :plans do
  # Chaves canônicas de feature E de limite vêm de Plan::MANAGED_FEATURE_KEYS / ::MANAGED_LIMIT_KEYS
  # (fonte única, também usada pela ponte Plano->conta e pela tela do Super Admin). Referenciadas em
  # RUNTIME dentro das tasks (sob :environment); não no corpo do namespace, para não acoplar o parse
  # do rake ao autoload do model.

  INTERNAL_SLUG = 'internal_unlimited'.freeze
  # Contas do grupo que recebem o plano interno (match por nome, case-insensitive).
  INTERNAL_ACCOUNT_NAMES = ['Athena', 'SCNET', 'Vale Mais Net'].freeze
  # Créditos de IA do plano interno: valor simbólico alto, não deve ter limite prático.
  INTERNAL_AI_CREDITS = 999_999

  # Preço do crédito extra de IA (recarga), igual nos 3 planos que usam IA integrada — Planos_Conexi_v2,
  # tabela de cadastro ("Custo créditos adicionais: R$0,07"). Enterprise não usa (chave própria sempre).
  AI_CREDIT_OVERAGE_PRICE_CENTS = 7

  # Cada plano: slug/name/description, monthly_price_cents (nil = sob consulta), courtesy (flag
  # manual — nunca visível/self-service), features (lista de MANAGED_FEATURE_KEYS ligadas, ou :all),
  # ai_credits (créditos mensais inclusos), limits (max_value por chave de Plan::MANAGED_LIMIT_KEYS; nil = ilimitado;
  # 0 = zero permitido), limit_overrides (política de excedente por chave; default hard_block).
  #
  # annual_price_cents / setup_fee_cents / promo_price_cents / promo_months_count: o seed agora GRAVA
  # essas colunas, mas as definições abaixo ainda não as trazem — os PDFs v2 dão os valores anuais
  # (START R$3.339,84 / PLUS R$5.738,88 / PRO+ R$9.587,52) e a implantação (R$5.000, gratuita no
  # pacote anual de PLUS/PRO+), e eles DIVERGEM do mensal que está aqui (v2: PLUS R$597,80 e PRO+
  # R$998,70; abaixo: 59_790 e 99_790). Preço é decisão de negócio: não mexo sem confirmação.
  #
  # A implantação gratuita no pacote anual não tem onde morar hoje — setup_fee_cents é uma coluna só,
  # sem distinção por ciclo de cobrança.
  PLANS = [
    {
      slug: 'start', name: 'START',
      description: 'Plano de entrada: canais essenciais, IA integrada e relatórios.',
      monthly_price_cents: 34_790,
      features: %w[dashboards_bi conversion_api],
      ai_credits: 500,
      limits: { 'users' => 3, 'inboxes' => 2, 'ai_agents' => 2, 'crm_pipelines' => 0 }
    },
    {
      slug: 'plus', name: 'PLUS',
      description: 'Mais canais, copiloto de IA e CRM em Kanban.',
      monthly_price_cents: 59_790,
      features: %w[
        webchat_channel facebook_channel dashboards_bi conversion_api ai_copilot webhook_api
        custom_llm_api_key crm_kanban crm_automations message_scheduling api_user_token
      ], # off no PLUS: sla_tracking, audit_logs, erp_integration, isp_ready_flows, account_manager
      ai_credits: 1000,
      limits: { 'users' => 10, 'inboxes' => 8, 'ai_agents' => 5, 'crm_pipelines' => 3 }
    },
    {
      slug: 'pro_plus', name: 'PRO +',
      description: 'Integração com ERP de ISP, SLA, auditoria e gerente de conta dedicado.',
      monthly_price_cents: 99_790,
      features: :all, # todas as MANAGED_FEATURE_KEYS ligadas
      ai_credits: 1000,
      limits: { 'users' => 30, 'inboxes' => 30, 'ai_agents' => nil, 'crm_pipelines' => nil },
      # Overage pago SÓ em 'users' ("Atendente adicional"): permite exceder 30 e cobra o excedente a
      # R$29,90/usuário (Planos_Conexi_v2). inboxes seguem hard_block; ai_agents/crm_pipelines já são
      # ilimitados. A cobrança de fato é débito da Fase 3 (Stripe/Asaas); aqui só grava a política.
      limit_overrides: { 'users' => { overflow_behavior: :paid_overage, overage_price_cents: 2990 } }
    },
    {
      slug: 'enterprise', name: 'Enterprise',
      description: 'Sob consulta: mesma cobertura do PRO+, sem limites de uso, chave de IA própria.',
      monthly_price_cents: nil, # sob consulta
      features: :all,
      ai_credits: 0, # sempre chave própria — não consome crédito da plataforma
      ai_credit_overage_price_cents: nil, # não aplicável (não usa o sistema de créditos da plataforma)
      limits: { 'users' => nil, 'inboxes' => nil, 'ai_agents' => nil, 'crm_pipelines' => nil }
    },
    {
      slug: 'courtesy', name: 'Cortesia',
      description: 'Acesso completo para parceiros/indicadores. Setado manualmente pela SCNET.',
      monthly_price_cents: 0,
      courtesy: true,
      visible: false, # nunca aparece para self-service — só atribuído manualmente
      features: :all,
      ai_credits: 0, # sem créditos inclusos — cobrados a parte (recarga dentro da Conexi)
      limits: { 'users' => nil, 'inboxes' => nil, 'ai_agents' => nil, 'crm_pipelines' => nil }
    }
  ].freeze

  desc 'Seed idempotente de planos + assinatura interna das 3 contas do grupo'
  task seed: :environment do
    seed_internal_plan
    seed_plans
    assign_internal_accounts
    puts '[plans:seed] concluído.'
    puts audit
  end

  # Trava anti-drift. Roda sozinha (CI/ops) e sai com status 1 quando há divergência: é o que faltava
  # para `pro`/`standard` terem sido notados — criados fora do seed, nunca configurados, e o sintoma
  # só apareceu meses depois numa conta que não conseguia usar a própria chave de IA.
  desc 'Confere o catálogo de planos contra o banco (falha se houver divergência)'
  task check: :environment do
    result = audit
    puts result
    exit(1) unless result.ok?
  end

  def audit
    known = PLANS.map { |attrs| attrs[:slug] } + [INTERNAL_SLUG]
    Plan::CatalogAudit.new(known_slugs: known)
  end

  def seed_internal_plan
    feature_keys = Plan::MANAGED_FEATURE_KEYS
    plan = Plan.find_or_initialize_by(slug: INTERNAL_SLUG)
    plan.update!(name: 'Interno (ilimitado)', active: true, visible_to_new_subscribers: false,
                 ai_credits_included: INTERNAL_AI_CREDITS)
    feature_keys.each do |key|
      feature = plan.plan_features.find_or_initialize_by(key: key)
      feature.update!(enabled: true)
    end
    Plan::MANAGED_LIMIT_KEYS.each do |key|
      limit = plan.plan_limits.find_or_initialize_by(key: key)
      limit.update!(max_value: nil, overflow_behavior: :hard_block) # nil = ilimitado
    end
    limites = Plan::MANAGED_LIMIT_KEYS.size
    puts "[plans:seed] plano interno '#{INTERNAL_SLUG}': #{feature_keys.size} features on, " \
         "#{limites} limites ilimitados, #{INTERNAL_AI_CREDITS} créditos IA."
  end

  def seed_plans
    feature_keys = Plan::MANAGED_FEATURE_KEYS
    PLANS.each do |attrs|
      plan = Plan.find_or_initialize_by(slug: attrs[:slug])
      plan.update!(
        name: attrs[:name],
        description: attrs[:description],
        active: true,
        visible_to_new_subscribers: attrs.fetch(:visible, true),
        courtesy: attrs.fetch(:courtesy, false),
        monthly_price_cents: attrs[:monthly_price_cents],
        # Colunas que os PDFs v2 especificam e o seed nunca gravava — ficam nil enquanto os valores
        # não forem confirmados (ver o comentário de preços acima). Plumbing pronto: basta preencher
        # annual_price_cents/setup_fee_cents/promo_* na definição do plano.
        annual_price_cents: attrs[:annual_price_cents],
        setup_fee_cents: attrs[:setup_fee_cents],
        promo_price_cents: attrs[:promo_price_cents],
        promo_months_count: attrs[:promo_months_count],
        ai_credits_included: attrs[:ai_credits],
        ai_credit_overage_price_cents: attrs.fetch(:ai_credit_overage_price_cents, AI_CREDIT_OVERAGE_PRICE_CENTS)
      )

      enabled = attrs[:features] == :all ? feature_keys : attrs[:features]

      # Grade completa de features (todas as MANAGED_FEATURE_KEYS): ligada se estiver em `enabled`.
      feature_keys.each do |key|
        feature = plan.plan_features.find_or_initialize_by(key: key)
        feature.update!(enabled: enabled.include?(key))
      end

      # Limites numéricos por chave. hard_block por padrão; limit_overrides ajusta política/preço por
      # chave (hoje só users no PRO+ => paid_overage). overage_price_cents nil quando não há override
      # (idempotente: re-run reseta chaves sem override).
      overrides = attrs[:limit_overrides] || {}
      attrs[:limits].each do |key, max_value|
        limit = plan.plan_limits.find_or_initialize_by(key: key)
        ov = overrides[key] || {}
        limit.update!(
          max_value: max_value,
          overflow_behavior: ov[:overflow_behavior] || :hard_block,
          overage_price_cents: ov[:overage_price_cents]
        )
      end

      puts "[plans:seed] plano '#{attrs[:slug]}': #{enabled.size}/#{feature_keys.size} features on, #{attrs[:ai_credits]} créditos IA, limites #{attrs[:limits]}."
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
