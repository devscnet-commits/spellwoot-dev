require 'rails_helper'

# Instagram cria a caixa dentro do callback OAuth (fora do allowed_channel_types). Controller spec, como o do OSS.
RSpec.describe Instagram::CallbacksController, type: :controller do
  let(:account) { create(:account) }
  let(:oauth_client) { instance_double(OAuth2::Client) }
  let(:auth_code_object) { instance_double(OAuth2::Strategy::AuthCode) }
  let(:access_token) { instance_double(OAuth2::AccessToken, token: 'test_token') }

  before do
    allow(controller).to receive_messages(verify_instagram_token: account.id, instagram_client: oauth_client,
                                          base_url: 'https://app.test', account: account,
                                          exchange_for_long_lived_token: { 'access_token' => 'long', 'expires_in' => 5_184_000 },
                                          fetch_instagram_user_details: { 'username' => 'loja', 'user_id' => '999' })
    allow(oauth_client).to receive(:auth_code).and_return(auth_code_object)
    allow(auth_code_object).to receive(:get_token).and_return(access_token)
    stub_request(:post, /graph.instagram.com/)
  end

  it 'Instagram fora do plano: não cria canal nem caixa' do
    subscribe_account_to_plan(account, features: Plan::MANAGED_FEATURE_KEYS - ['instagram_channel'])
    RequestStore.clear!

    expect { get :show, params: { code: 'c', state: "#{account.id}|t" } }.not_to change(Channel::Instagram, :count)
    expect(account.inboxes.count).to eq(0)
  end

  it 'limite cheio: não cria canal nem caixa' do
    create(:inbox, account: account)
    subscribe_account_to_plan(account, features: Plan::MANAGED_FEATURE_KEYS, limits: { 'inboxes' => 1 })
    RequestStore.clear!

    expect { get :show, params: { code: 'c', state: "#{account.id}|t" } }.not_to change(Channel::Instagram, :count)
    expect(account.inboxes.count).to eq(1)
  end
end
