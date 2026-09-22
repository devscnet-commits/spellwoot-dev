require 'rails_helper'

RSpec.describe 'Api::V1::Accounts::IntegrationSettings' do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }

  describe 'PUT /api/v1/accounts/{account.id}/integration_settings/{provider}' do
    # Salvar NÃO chama o provider: o controller só persiste. Quem valida com chamada real é a ação
    # explícita test_connection (Ai::KeyCheck para openai). Estes exemplos não usam stub de propósito
    # — com o WebMock barrando a rede, qualquer chamada durante o save estouraria o teste, então a
    # ausência de erro é a própria prova de que o save não fala com ninguém.
    context 'when saving a key' do
      it 'persiste sem chamar o provider' do
        put "/api/v1/accounts/#{account.id}/integration_settings/anthropic",
            params: { config: { apiKey: 'qualquer-chave' }, enabled: true },
            headers: admin.create_new_auth_token

        expect(response).to have_http_status(:success)
        setting = IntegrationSetting.find_by(account_id: account.id, provider: 'anthropic')
        expect(setting.config_hash['apiKey']).to eq('qualquer-chave')
      end

      it 'não devolve a chave em texto puro na resposta do save' do
        put "/api/v1/accounts/#{account.id}/integration_settings/anthropic",
            params: { config: { apiKey: 'sk-SEGREDO-do-cliente' }, enabled: true },
            headers: admin.create_new_auth_token

        expect(response.body).not_to include('sk-SEGREDO-do-cliente')
        expect(response.parsed_body.dig('config', 'apiKey')).to include('*')
      end

      it 'persiste a desativação' do
        put "/api/v1/accounts/#{account.id}/integration_settings/anthropic",
            params: { config: { apiKey: 'whatever' }, enabled: false },
            headers: admin.create_new_auth_token

        expect(response).to have_http_status(:success)
        expect(IntegrationSetting.find_by(account_id: account.id, provider: 'anthropic').enabled).to be(false)
      end
    end

    context 'with a legacy provider (n8n, outside BYOK)' do
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
