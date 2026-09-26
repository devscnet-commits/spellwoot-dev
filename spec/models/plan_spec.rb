require 'rails_helper'

RSpec.describe Plan do
  let(:account) { create(:account) }

  describe '#apply_feature_grid!' do
    let(:plan) { described_class.create!(name: 'Teste', slug: "teste-#{SecureRandom.hex(3)}") }

    it 'grava ligado só o que veio marcado e desligado todo o resto da lista canônica' do
      plan.apply_feature_grid!(%w[whatsapp_channel email_channel])

      expect(plan.feature_enabled?('whatsapp_channel')).to be(true)
      expect(plan.feature_enabled?('email_channel')).to be(true)
      expect(plan.feature_enabled?('instagram_channel')).to be(false)
      expect(plan.plan_features.count).to eq(described_class::MANAGED_FEATURE_KEYS.size)
    end

    it 'grava "Todas" (oficiais + não oficiais) quando o WhatsApp está marcado' do
      plan.apply_feature_grid!(%w[whatsapp_channel whatsapp_unofficial_channel])

      expect(plan.feature_enabled?('whatsapp_unofficial_channel')).to be(true)
    end

    it 'grava "Somente oficiais" quando a sub-opção vem vazia' do
      plan.apply_feature_grid!(['whatsapp_channel', ''])

      expect(plan.feature_enabled?('whatsapp_channel')).to be(true)
      expect(plan.feature_enabled?('whatsapp_unofficial_channel')).to be(false)
    end

    it 'não deixa não oficial ligado sem o WhatsApp base' do
      plan.apply_feature_grid!(%w[whatsapp_unofficial_channel])

      expect(plan.feature_enabled?('whatsapp_unofficial_channel')).to be(false)
    end

    it 'ignora chave que não está na lista canônica' do
      plan.apply_feature_grid!(%w[inventada])

      expect(plan.plan_features.pluck(:key)).not_to include('inventada')
    end
  end

  describe 'sincronização com a conta' do
    it 'liga na conta as flags do plano e desliga as que o plano não traz' do
      plan = subscribe_account_to_plan(account, features: %w[whatsapp_channel])

      account.reload
      expect(account.feature_enabled?('channel_whatsapp')).to be(true)
      expect(account.feature_enabled?('channel_whatsapp_unofficial')).to be(false)
      expect(account.feature_enabled?('channel_instagram')).to be(false)

      plan.apply_feature_grid!(%w[whatsapp_channel whatsapp_unofficial_channel instagram_channel])
      plan.sync_features_to!(account)

      account.reload
      expect(account.feature_enabled?('channel_whatsapp_unofficial')).to be(true)
      expect(account.feature_enabled?('channel_instagram')).to be(true)
    end

    it 'tirar uma feature do plano tira da conta na próxima sincronização' do
      plan = subscribe_account_to_plan(account, features: %w[whatsapp_channel whatsapp_unofficial_channel])
      expect(account.reload.feature_enabled?('channel_whatsapp_unofficial')).to be(true)

      plan.apply_feature_grid!(%w[whatsapp_channel])
      plan.sync_features_to!(account)

      expect(account.reload.feature_enabled?('channel_whatsapp_unofficial')).to be(false)
    end

    it 'não mexe em features da conta que o plano não gerencia' do
      account.enable_features!('help_center')

      subscribe_account_to_plan(account, features: [])

      expect(account.reload.feature_enabled?('help_center')).to be(true)
    end

    it 'carrega os créditos de IA do plano no saldo da conta ao assinar' do
      subscribe_account_to_plan(account, ai_credits: 1000)

      expect(account.reload.ai_credit_balance.plan_credits).to eq(1000)
    end
  end

  describe 'catálogo' do
    it 'toda chave do plano aponta para uma flag que existe em config/features.yml' do
      conhecidas = SuperAdmin::AccountFeaturesHelper.account_features.pluck('name')

      expect(described_class::PLAN_FEATURE_TO_ACCOUNT_FLAG.values - conhecidas).to be_empty
    end

    it 'toda chave de feature e de limite tem rótulo em português na tela do Super Admin' do
      expect(described_class::MANAGED_FEATURE_KEYS - described_class::FEATURE_LABELS.keys).to be_empty
      expect(described_class::MANAGED_LIMIT_KEYS - described_class::LIMIT_LABELS.keys).to be_empty
      expect(PlanLimit.overflow_behaviors.keys - described_class::OVERFLOW_BEHAVIOR_LABELS.keys).to be_empty
    end

    it 'as grades da tela usam os rótulos em português' do
      plan = described_class.create!(name: 'Teste', slug: "teste-#{SecureRandom.hex(3)}")

      expect(plan.feature_grid['whatsapp_unofficial_channel'][:display_name]).to eq('WhatsApp não oficial')
      expect(plan.limit_grid['users'][:label]).to eq('Usuários')
    end
  end
end
