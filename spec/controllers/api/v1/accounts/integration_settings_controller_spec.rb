require 'rails_helper'

RSpec.describe 'Integration Settings API', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }

  def show_provider(provider)
    get "/api/v1/accounts/#{account.id}/integration_settings/#{provider}", headers: admin.create_new_auth_token, as: :json
  end

  context 'when o plano é "Somente oficiais"' do
    before { subscribe_account_to_plan(account, features: %w[whatsapp_channel]) }

    it 'recusa as integrações de WhatsApp não oficial' do
      %w[uazapi evolution_api].each do |provider|
        show_provider(provider)

        expect(response).to have_http_status(:forbidden)
      end
    end

    it 'recusa também salvar configuração de provedor não oficial' do
      put "/api/v1/accounts/#{account.id}/integration_settings/uazapi",
          params: { config: { apiUrl: 'https://x.uazapi.com' } }, headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:forbidden)
      expect(IntegrationSetting.where(account_id: account.id, provider: 'uazapi')).to be_empty
    end

    it 'continua liberando as demais integrações' do
      show_provider('meta')

      expect(response).to have_http_status(:ok)
    end
  end

  context 'when o plano libera WhatsApp com "Todas"' do
    before { subscribe_account_to_plan(account, features: %w[whatsapp_channel whatsapp_unofficial_channel]) }

    it 'libera as integrações de WhatsApp não oficial' do
      show_provider('uazapi')

      expect(response).to have_http_status(:ok)
    end
  end
end
