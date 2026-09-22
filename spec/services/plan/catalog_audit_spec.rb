require 'rails_helper'

# A divergência que esta auditoria existe para pegar chegou em produção sem ninguém ver: `pro` e
# `standard` foram criados fora do seed, portanto plans:seed nunca os tocou, e viveram sem nenhuma
# PlanFeature. O sintoma só apareceu meses depois, numa conta que não conseguia usar a própria chave.
RSpec.describe Plan::CatalogAudit do
  def plan!(slug, courtesy: false)
    Plan.create!(name: slug.humanize, slug: slug, courtesy: courtesy)
  end

  def fully_configured!(slug)
    plan = plan!(slug)
    Plan::MANAGED_FEATURE_KEYS.each { |k| plan.plan_features.create!(key: k, enabled: true) }
    Plan::MANAGED_LIMIT_KEYS.each { |k| plan.plan_limits.create!(key: k, max_value: nil) }
    plan
  end

  describe 'plano fora do catálogo' do
    it 'aponta o plano que existe no banco mas o seed não conhece' do
      fully_configured!('start')
      fully_configured!('pro')

      issues = described_class.new(known_slugs: %w[start]).issues

      expect(issues.map(&:kind)).to include('fora-do-catálogo')
      expect(issues.find { |i| i.kind == 'fora-do-catálogo' }.slug).to eq('pro')
    end

    it 'não aponta nada quando todo plano do banco está no catálogo' do
      fully_configured!('start')

      kinds = described_class.new(known_slugs: %w[start]).issues.map(&:kind)
      expect(kinds).not_to include('fora-do-catálogo')
    end
  end

  describe 'plano sem grade' do
    # Linha ausente lê como "desligada" (Plan#feature_enabled?), então zero linhas é indistinguível
    # de "tudo desligado de propósito" — e é quase sempre um plano que ninguém configurou.
    it 'aponta o plano sem nenhuma PlanFeature' do
      plan!('standard')

      expect(described_class.new(known_slugs: %w[standard]).issues.map(&:kind)).to include('sem-grade')
    end
  end

  describe 'plano comercial fora de COMMERCIAL_RANK' do
    # commercial_rank nil faz Plan::ChangeSubscriptionService#upgrade! levantar — o upgrade
    # self-service simplesmente não funciona para contas nesse plano.
    it 'aponta o plano comercial sem rank' do
      fully_configured!('pro')

      expect(described_class.new(known_slugs: %w[pro]).issues.map(&:kind)).to include('sem-rank')
    end

    it 'não cobra rank de plano cortesia nem do interno' do
      cortesia = plan!('courtesy', courtesy: true)
      Plan::MANAGED_FEATURE_KEYS.each { |k| cortesia.plan_features.create!(key: k, enabled: true) }
      Plan::MANAGED_LIMIT_KEYS.each { |k| cortesia.plan_limits.create!(key: k, max_value: nil) }
      fully_configured!('internal_unlimited')

      kinds = described_class.new(known_slugs: %w[courtesy internal_unlimited]).issues.map(&:kind)
      expect(kinds).not_to include('sem-rank')
    end
  end

  describe 'invariantes de código (independem do banco)' do
    # enable_features gravando um bit que ninguém lê = toggle que não faz nada na tela do Super Admin.
    it 'toda chave gerenciada aponta para uma flag que existe em config/features.yml' do
      conhecidas = SuperAdmin::AccountFeaturesHelper.account_features.pluck('name')

      expect(Plan::PLAN_FEATURE_TO_ACCOUNT_FLAG.values - conhecidas).to be_empty
    end

    it 'catálogo em dia não produz achado nenhum' do
      fully_configured!('start') # 'start' está em COMMERCIAL_RANK, com grade e limites completos

      expect(described_class.new(known_slugs: %w[start]).issues.map(&:kind)).to be_empty
    end
  end
end
