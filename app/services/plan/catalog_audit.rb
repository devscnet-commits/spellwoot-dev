# Auditoria do catálogo de planos: aponta a DIVERGÊNCIA entre o que o código conhece e o que existe
# no banco. Existe porque essa divergência já chegou em produção sem ninguém ver — os planos `pro` e
# `standard` foram criados fora do seed, portanto `plans:seed` nunca os tocou, e eles viveram sem
# nenhuma PlanFeature. O efeito prático levou meses para aparecer: conta em plano sem feature não
# libera chave própria de IA, e plano fora de COMMERCIAL_RANK não faz upgrade self-service.
#
# Só LÊ. Quem corrige é a tela do Super Admin (features/limites) ou o seed.
class Plan::CatalogAudit
  Issue = Struct.new(:kind, :slug, :detail, keyword_init: true)

  # known_slugs: os slugs que o seed conhece (lib/tasks/plans.rake os informa). Sem eles a auditoria
  # ainda roda, mas não consegue apontar "plano fora do catálogo" — o achado mais importante.
  def initialize(known_slugs: [])
    @known_slugs = known_slugs.map(&:to_s)
  end

  def issues
    @issues ||= orphan_plans + empty_grids + missing_limits + rankless_commercial + dangling_flags
  end

  def ok?
    issues.empty?
  end

  def to_s
    return '[plans:check] catálogo e banco em dia.' if ok?

    (["[plans:check] #{issues.size} divergência(s):"] +
      issues.map { |i| "  - #{i.kind} #{i.slug}: #{i.detail}" }).join("\n")
  end

  private

  # O caso `pro`/`standard`: existe no banco, o seed não conhece, ninguém o mantém.
  def orphan_plans
    return [] if @known_slugs.empty?

    Plan.where.not(slug: @known_slugs).pluck(:slug).map do |slug|
      Issue.new(kind: 'fora-do-catálogo', slug: slug,
                detail: 'existe no banco mas não no seed — plans:seed nunca vai configurá-lo')
    end
  end

  # Linha ausente de PlanFeature lê como "desligada" (Plan#feature_enabled?), então um plano com
  # ZERO linhas é indistinguível de um plano com tudo desligado de propósito — e quase sempre é o
  # primeiro caso.
  def empty_grids
    Plan.left_joins(:plan_features).group(:id).having('COUNT(plan_features.id) = 0').pluck(:slug).map do |slug|
      Issue.new(kind: 'sem-grade', slug: slug,
                detail: 'nenhuma PlanFeature — toda feature gerenciada lê como desligada')
    end
  end

  def missing_limits
    Plan.includes(:plan_limits).filter_map do |plan|
      faltando = Plan::MANAGED_LIMIT_KEYS - plan.plan_limits.map(&:key)
      next if faltando.empty?

      Issue.new(kind: 'sem-limite', slug: plan.slug, detail: "sem PlanLimit para #{faltando.join(', ')}")
    end
  end

  # Plano comercial (não interno, não cortesia) fora de COMMERCIAL_RANK: commercial_rank devolve nil e
  # Plan::ChangeSubscriptionService#upgrade! levanta 'Plano atual não permite troca automática'.
  def rankless_commercial
    Plan.where(courtesy: false).filter_map do |plan|
      next if plan.commercial_rank.present? || plan.slug == 'internal_unlimited'

      Issue.new(kind: 'sem-rank', slug: plan.slug,
                detail: 'fora de Plan::COMMERCIAL_RANK — upgrade self-service falha neste plano')
    end
  end

  # Chave gerenciada apontando para uma flag que não existe em config/features.yml: enable_features
  # grava um bit que ninguém lê, e a tela mostra um toggle que não faz nada.
  def dangling_flags
    conhecidas = SuperAdmin::AccountFeaturesHelper.account_features.pluck('name')
    Plan::PLAN_FEATURE_TO_ACCOUNT_FLAG.filter_map do |plan_key, account_flag|
      next if conhecidas.include?(account_flag)

      Issue.new(kind: 'flag-inexistente', slug: plan_key,
                detail: "mapeia para '#{account_flag}', que não existe em config/features.yml")
    end
  end
end
