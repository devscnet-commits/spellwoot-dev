require 'rails_helper'

# Conectores externos guardam credencial em `auth`/`headers` e o index serializa o registro inteiro.
# A BaseController de conta não autoriza nada — só resolve a conta e checa se o agente está ativo —
# então sem policy própria qualquer agente ativo lia o bearer token do cliente.
RSpec.describe 'Api::V1::Accounts::AiIntegrationLinks' do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agente) { create(:user, account: account, role: :agent) }
  let(:segredo) { 'Bearer SEGREDO-do-conector' }

  let!(:link) do
    Ai::IntegrationLink.create!(account_id: account.id, name: 'ERP', kind: 'webhook',
                                endpoint: 'https://erp.example.com/api', http_method: 'POST',
                                auth: { 'type' => 'bearer', 'token' => segredo },
                                headers: { 'Authorization' => segredo }, payload_template: {})
  end

  describe 'GET /api/v1/accounts/{account.id}/ai_integration_links' do
    it 'nega a um agente comum, sem devolver a credencial' do
      get "/api/v1/accounts/#{account.id}/ai_integration_links", headers: agente.create_new_auth_token

      expect(response).to have_http_status(:unauthorized)
      expect(response.body).not_to include(segredo)
    end

    it 'permite ao administrador' do
      get "/api/v1/accounts/#{account.id}/ai_integration_links", headers: admin.create_new_auth_token

      expect(response).to have_http_status(:success)
      expect(response.parsed_body.first['name']).to eq('ERP')
    end

    it 'nega ao administrador de OUTRA conta' do
      intruso = create(:user, account: create(:account), role: :administrator)

      get "/api/v1/accounts/#{account.id}/ai_integration_links", headers: intruso.create_new_auth_token

      expect(response).not_to have_http_status(:success)
      expect(response.body).not_to include(segredo)
    end
  end

  describe 'escrita' do
    it 'nega a criação a um agente comum' do
      expect do
        post "/api/v1/accounts/#{account.id}/ai_integration_links",
             params: { name: 'Novo', kind: 'webhook', endpoint: 'https://x.test' },
             headers: agente.create_new_auth_token
      end.not_to change(Ai::IntegrationLink, :count)

      expect(response).to have_http_status(:unauthorized)
    end

    it 'nega a exclusão a um agente comum' do
      expect do
        delete "/api/v1/accounts/#{account.id}/ai_integration_links/#{link.id}",
               headers: agente.create_new_auth_token
      end.not_to change(Ai::IntegrationLink, :count)
    end
  end
end
