require 'rails_helper'

RSpec.describe Migration::UazapiIgnoreGroupsJob do
  let(:account) { create(:account) }
  let!(:channel) { create(:channel_api, account: account, additional_attributes: { 'uazapi_instance_token' => 'inst-token' }) }
  let(:inbox) { channel.inbox }

  before do
    create(:user, account: account, role: :administrator)
    allow(Whatsapp::Providers::UazapiService).to receive(:credentials_for).and_return({ webhook_base_url: 'https://app.test' })
  end

  it 'reaplica a integração das inboxes UazAPI existentes com ignore_groups: true' do
    request = stub_request(:put, %r{/chatwoot/config})
              .with(headers: { 'token' => 'inst-token' }, body: hash_including('ignore_groups' => true, 'inbox_id' => inbox.id))
              .to_return(status: 200, body: { chatwoot_inbox_webhook_url: 'https://app.test/hook' }.to_json,
                         headers: { 'Content-Type' => 'application/json' })

    described_class.perform_now

    expect(request).to have_been_requested
    expect(channel.reload.webhook_url).to eq('https://app.test/hook')
  end

  it 'nenhum chamador consegue ligar grupos na UazAPI' do
    request = stub_request(:put, %r{/chatwoot/config}).with(body: hash_including('ignore_groups' => true)).to_return(status: 200, body: '{}')

    Whatsapp::Providers::UazapiService.configure_chatwoot_integration('inst-token', { 'ignore_groups' => false }, account_id: account.id)

    expect(request).to have_been_requested
  end
end
