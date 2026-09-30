require 'rails_helper'

# Módulo "Token de acesso pessoal (API)" do plano: sem ele a tela de perfil não mostra o token e não dá para
# regenerá-lo. O token continua existindo e autenticando — o próprio painel (upload de anexos) e a integração
# UazAPI usam o token do usuário.
RSpec.describe 'Token de acesso pessoal pelo plano', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:headers) { admin.create_new_auth_token }

  def plan(with_token:)
    keys = Plan::MANAGED_FEATURE_KEYS - (with_token ? [] : ['api_user_token'])
    subscribe_account_to_plan(account, features: keys)
    RequestStore.clear!
  end

  describe 'GET /api/v1/accounts/:id (flag para a tela de perfil)' do
    it 'plano sem o módulo: false' do
      plan(with_token: false)
      get "/api/v1/accounts/#{account.id}", headers: headers, as: :json

      expect(response.parsed_body['api_user_token_allowed']).to be(false)
    end

    it 'plano com o módulo: true' do
      plan(with_token: true)
      get "/api/v1/accounts/#{account.id}", headers: headers, as: :json

      expect(response.parsed_body['api_user_token_allowed']).to be(true)
    end

    it 'conta sem plano: true (regra das travas de módulo — sem plano não trava)' do
      get "/api/v1/accounts/#{account.id}", headers: headers, as: :json

      expect(response.parsed_body['api_user_token_allowed']).to be(true)
    end
  end

  describe 'POST /api/v1/profile/reset_access_token' do
    it 'plano sem o módulo: 403 e o token não muda' do
      plan(with_token: false)
      token_before = admin.access_token.token

      post '/api/v1/profile/reset_access_token', headers: headers, as: :json

      expect(response).to have_http_status(:forbidden)
      expect(admin.access_token.reload.token).to eq(token_before)
    end

    it 'plano com o módulo: regenera' do
      plan(with_token: true)
      token_before = admin.access_token.token

      post '/api/v1/profile/reset_access_token', headers: headers, as: :json

      expect(response).to have_http_status(:success)
      expect(admin.access_token.reload.token).not_to eq(token_before)
    end

    it 'sem o módulo, o token segue autenticando (anexos do painel e UazAPI dependem dele)' do
      plan(with_token: false)

      get "/api/v1/accounts/#{account.id}/inboxes", headers: { api_access_token: admin.access_token.token }, as: :json

      expect(response).to have_http_status(:success)
    end
  end
end
