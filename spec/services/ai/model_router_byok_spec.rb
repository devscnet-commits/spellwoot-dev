require 'rails_helper'

# BYOK (billing Fase 3): resolução da chave própria da conta no Ai::ModelRouter.
RSpec.describe Ai::ModelRouter do
  let(:account) { create(:account) }

  def set_hub_key(provider, key)
    IntegrationSetting.create!(account_id: account.id, provider: provider, enabled: true,
                               config: { 'apiKey' => key }.to_json)
  end

  describe '.account_provider_key' do
    it 'usa a chave própria da conta quando a feature custom_llm_api_key está ligada' do
      account.enable_features!('custom_llm_api_key')
      set_hub_key('anthropic', 'sk-ant-conta')

      expect(described_class.account_provider_key(account.id, 'anthropic')).to eq('sk-ant-conta')
    end

    it 'NUNCA usa a chave da conta sem a feature, mesmo com uma linha órfã no Hub' do
      set_hub_key('anthropic', 'sk-ant-orfa') # linha existe, mas a feature está OFF

      expect(described_class.account_provider_key(account.id, 'anthropic')).to be_nil
    end

    it 'retorna nil quando a conta tem a feature mas não configurou chave' do
      account.enable_features!('custom_llm_api_key')

      expect(described_class.account_provider_key(account.id, 'groq')).to be_nil
    end
  end

  describe '.byok_key (force_global_key)' do
    it 'ignora a chave da conta quando force_global_key é true (retry pós-falha)' do
      account.enable_features!('custom_llm_api_key')
      set_hub_key('gemini', 'gm-conta')

      expect(described_class.byok_key(account.id, 'gemini', true)).to be_nil
      expect(described_class.byok_key(account.id, 'gemini', false)).to eq('gm-conta')
    end
  end

  describe '.provider_context threading' do
    it 'consulta a chave própria no caminho normal e a ignora com force_global_key' do
      expect(described_class).to receive(:byok_key).with(account.id, 'anthropic', false).and_return('sk-ant-x')
      described_class.provider_context('anthropic', account_id: account.id)

      expect(described_class).to receive(:byok_key).with(account.id, 'anthropic', true).and_return(nil)
      # sem chave da conta e sem global configurada, o context deve exigir a chave -> levanta
      allow(described_class).to receive(:credential).and_return(nil)
      expect { described_class.provider_context('anthropic', account_id: account.id, force_global_key: true) }
        .to raise_error(/anthropic_api_key ausente/)
    end
  end
end
