require 'rails_helper'

RSpec.describe 'Api::V1::Accounts::IntegrationSettings' do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }

  describe 'PUT /api/v1/accounts/{account.id}/integration_settings/{provider}' do
    # BYOK (billing Fase 3): a chave própria é validada com chamada real antes de salvar.
    context 'com um provider BYOK (anthropic)' do
      it 'rejeita com 422 quando a chave não passa no teste real' do
        stub_request(:get, 'https://api.anthropic.com/v1/models').to_return(status: 401)

        put "/api/v1/accounts/#{account.id}/integration_settings/anthropic",
            params: { config: { apiKey: 'bad-key' }, enabled: true },
            headers: admin.create_new_auth_token

        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.parsed_body['error']).to match(/inválida ou revogada/)
        expect(IntegrationSetting.find_by(account_id: account.id, provider: 'anthropic')).to be_nil
      end

      it 'aceita e persiste quando a chave é válida' do
        stub_request(:get, 'https://api.anthropic.com/v1/models').to_return(status: 200, body: '{"data":[]}')

        put "/api/v1/accounts/#{account.id}/integration_settings/anthropic",
            params: { config: { apiKey: 'good-key' }, enabled: true },
            headers: admin.create_new_auth_token

        expect(response).to have_http_status(:success)
        setting = IntegrationSetting.find_by(account_id: account.id, provider: 'anthropic')
        expect(setting.config_hash['apiKey']).to eq('good-key')
      end

      it 'não valida (nem chama o provider) ao apenas DESATIVAR' do
        # sem stub: se disparasse a chamada, o WebMock estouraria. enabled=false pula a validação.
        put "/api/v1/accounts/#{account.id}/integration_settings/anthropic",
            params: { config: { apiKey: 'whatever' }, enabled: false },
            headers: admin.create_new_auth_token

        expect(response).to have_http_status(:success)
        expect(IntegrationSetting.find_by(account_id: account.id, provider: 'anthropic').enabled).to be(false)
      end
    end

    context 'com um provider legado (n8n, fora do BYOK)' do
      it 'salva sem disparar validação externa' do
        # n8n não é BYOK: nenhuma chamada de teste é feita no save (comportamento legado preservado).
        put "/api/v1/accounts/#{account.id}/integration_settings/n8n",
            params: { config: { webhookUrl: 'https://n8n.example.com/webhook/x', token: 't' }, enabled: true },
            headers: admin.create_new_auth_token

        expect(response).to have_http_status(:success)
      end
    end
  end
end
