require 'rails_helper'

RSpec.describe Migration::UazapiIgnoreGroupsJob do
  let(:account) { create(:account) }
  let(:current_config) do
    { chatwoot_enabled: true, chatwoot_url: 'https://app.test', chatwoot_access_token: 'token-original',
      chatwoot_account_id: account.id, chatwoot_inbox_id: 55, chatwoot_ignore_groups: false,
      chatwoot_sign_messages: true, chatwoot_create_new_conversation: false }
  end

  before do
    create(:channel_api, account: account, additional_attributes: { 'uazapi_instance_token' => 'inst-token' })
    allow(Whatsapp::Providers::UazapiService).to receive(:base_url).and_return('https://uaz.test')
  end

  def stub_current(config)
    stub_request(:get, 'https://uaz.test/chatwoot/config')
      .to_return(status: 200, body: config.to_json, headers: { 'Content-Type' => 'application/json' })
  end

  it 'liga ignore_groups mantendo token, inbox e demais opções da instância' do
    stub_current(current_config)
    put = stub_request(:put, 'https://uaz.test/chatwoot/config').with(
      headers: { 'token' => 'inst-token' },
      body: { enabled: true, url: 'https://app.test', access_token: 'token-original', account_id: account.id, inbox_id: 55,
              ignore_groups: true, sign_messages: true, create_new_conversation: false }.to_json
    ).to_return(status: 200, body: '{}')

    described_class.perform_now

    expect(put).to have_been_requested
  end

  it 'não mexe em instância com a integração desligada ou que já ignora grupos' do
    stub_current(current_config.merge(chatwoot_ignore_groups: true))
    put = stub_request(:put, 'https://uaz.test/chatwoot/config')

    described_class.perform_now

    expect(put).not_to have_been_requested
  end
end
