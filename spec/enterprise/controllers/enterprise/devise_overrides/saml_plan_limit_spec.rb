require 'rails_helper'

# Primeiro login por SSO numa conta com o limite de usuários do plano cheio: volta para o login com um aviso
# próprio (não o "autenticação falhou" genérico) e não deixa o usuário criado sem conta.
RSpec.describe 'SAML com limite de usuários do plano', type: :request do
  let!(:account) { create(:account) }

  before do
    allow(ChatwootApp).to receive(:enterprise?).and_return(true)
    create(:user, account: account)
    subscribe_account_to_plan(account, features: Plan::MANAGED_FEATURE_KEYS, limits: { 'users' => 1 })
    account.enable_features!('saml')
    create(:account_saml_settings, account: account)
    RequestStore.clear!
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:saml] = OmniAuth::AuthHash.new(provider: 'saml', uid: 'sso-1',
                                                              info: { name: 'SSO', email: 'sso-novo@example.com' })
  end

  it 'redireciona com saml-user-limit e não cria o usuário' do
    with_modified_env FRONTEND_URL: 'http://www.example.com' do
      get "/omniauth/saml/callback?account_id=#{account.id}"
      follow_redirect!

      expect(response).to redirect_to('http://www.example.com/app/login?error=saml-user-limit')
    end
    expect(User.from_email('sso-novo@example.com')).to be_nil
    expect(account.account_users.count).to eq(1)
  end
end
