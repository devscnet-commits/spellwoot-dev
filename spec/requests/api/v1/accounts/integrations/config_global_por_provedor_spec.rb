require 'rails_helper'

# Só os servidores COMPARTILHADOS da plataforma (UazAPI, Evolution) herdam a config global/ENV. Os provedores do
# negócio do cliente (Meta, Bitrix, n8n, Google, chave de IA) usam só o que a conta cadastrou. Achado ao vivo:
# a aba "APIs & Credenciais" de um cliente mostrava o Pixel/Token/Test Event Code da Meta da plataforma com o
# selo "Global" — e a API de Conversões enviava os leads do cliente para o Pixel da plataforma.
RSpec.describe 'Config global por provedor' do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:meta_global) { { pixelId: '931618603010277', accessToken: 'EAA-da-plataforma', testEventCode: 'TEST81275' } }

  before { IntegrationSetting.create!(account_id: nil, provider: 'meta', enabled: true, config: meta_global.to_json) }

  describe 'IntegrationSettingsService.get_config' do
    it 'Meta: conta sem config própria não herda o global nem o ENV' do
      with_modified_env(META_PIXEL_ID: 'env-pixel', META_CONVERSIONS_API_TOKEN: 'env-token') do
        expect(IntegrationSettingsService.get_config(account.id, 'meta')).to eq({})
        expect(IntegrationSettingsService.get_config(account.id, 'meta', for_display: true)).to eq({})
      end
    end

    it 'Meta: usa só o que a conta cadastrou (sem completar com o Test Event Code global)' do
      IntegrationSetting.create!(account_id: account.id, provider: 'meta', enabled: true,
                                 config: { pixelId: 'pixel-do-cliente', accessToken: 'token-do-cliente' }.to_json)

      expect(IntegrationSettingsService.get_config(account.id, 'meta'))
        .to eq('pixelId' => 'pixel-do-cliente', 'accessToken' => 'token-do-cliente')
    end

    it 'Bitrix, n8n, Google e OpenAI: não herdam o global' do
      %w[bitrix n8n google openai].each do |provider|
        IntegrationSetting.create!(account_id: nil, provider: provider, enabled: true, config: { token: 'global', apiKey: 'global' }.to_json)

        expect(IntegrationSettingsService.get_config(account.id, provider)).to eq({}), provider
      end
    end

    it 'UazAPI (servidor compartilhado): continua herdando o global, com a conta sobrepondo' do
      IntegrationSetting.create!(account_id: nil, provider: 'uazapi', enabled: true,
                                 config: { apiUrl: 'https://uaz.plataforma', token: 'admin-global' }.to_json)
      expect(IntegrationSettingsService.get_config(account.id, 'uazapi'))
        .to eq('apiUrl' => 'https://uaz.plataforma', 'token' => 'admin-global')

      IntegrationSetting.create!(account_id: account.id, provider: 'uazapi', enabled: true, config: { token: 'da-conta' }.to_json)
      expect(IntegrationSettingsService.get_config(account.id, 'uazapi'))
        .to eq('apiUrl' => 'https://uaz.plataforma', 'token' => 'da-conta')
    end
  end

  describe 'GET /integration_settings/meta (tela APIs & Credenciais)' do
    it 'conta sem config própria: nenhum valor nem selo "Global"' do
      get "/api/v1/accounts/#{account.id}/integration_settings/meta", headers: admin.create_new_auth_token

      expect(response.parsed_body['config']).to eq({})
      expect(response.parsed_body['sources']).to eq({})
      expect(response.body).not_to include('931618603010277', 'TEST81275')
    end
  end

  describe 'POST /integration_settings/:provider/import_from_env' do
    it 'admin de conta não grava a config global' do
      with_modified_env(UAZAPI_BASE_URL: 'https://uaz.env') do
        post "/api/v1/accounts/#{account.id}/integration_settings/uazapi/import_from_env", headers: admin.create_new_auth_token
      end

      expect(response).to have_http_status(:unauthorized)
      expect(IntegrationSetting.find_by(account_id: nil, provider: 'uazapi')).to be_nil
    end
  end

  describe 'Meta::ConversionsApiService' do
    let!(:conversation) { create(:conversation, account: account) }

    it 'conta sem Pixel próprio não envia para o Pixel da plataforma' do
      account.update!(settings: { 'meta_conversion_settings' => { 'enabled' => true } })
      subscribe_account_to_plan(account, features: ['conversion_api'])
      conversation.update!(custom_attributes: { 'ctwa_clid' => 'clid' })

      expect(Meta::ConversionsApiService.track_lead(conversation)).to be_nil
      expect(a_request(:post, /graph.facebook.com/)).not_to have_been_made
    end
  end
end
