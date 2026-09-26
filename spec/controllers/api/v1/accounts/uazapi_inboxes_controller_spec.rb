require 'rails_helper'

RSpec.describe 'UazAPI Inboxes API', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:params) { { name: 'WhatsApp QR', phone_number: '5511999998888' } }

  def create_uazapi_inbox
    post "/api/v1/accounts/#{account.id}/uazapi_inboxes", params: params, headers: admin.create_new_auth_token, as: :json
  end

  # O serviço real fala com o servidor UazAPI; aqui só interessa saber se a requisição passou pelos
  # gates do plano e chegou nele.
  def stub_connection_service
    service = instance_double(Whatsapp::UazapiConnectionService, perform: { success: false, error: 'chegou no serviço' })
    allow(Whatsapp::UazapiConnectionService).to receive(:new).and_return(service)
  end

  before { stub_connection_service }

  it 'cria quando o plano libera WhatsApp com "Todas"' do
    subscribe_account_to_plan(account, features: %w[whatsapp_channel whatsapp_unofficial_channel])

    create_uazapi_inbox

    expect(Whatsapp::UazapiConnectionService).to have_received(:new)
    expect(response.parsed_body['error']).to eq('chegou no serviço')
  end

  it 'recusa quando o plano é "Somente oficiais"' do
    subscribe_account_to_plan(account, features: %w[whatsapp_channel])

    create_uazapi_inbox

    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body['error']).to include('apenas integrações oficiais')
    expect(Whatsapp::UazapiConnectionService).not_to have_received(:new)
  end

  it 'recusa quando o plano não tem WhatsApp' do
    subscribe_account_to_plan(account, features: [])

    create_uazapi_inbox

    expect(response).to have_http_status(:forbidden)
    expect(Whatsapp::UazapiConnectionService).not_to have_received(:new)
  end

  it 'recusa quando o limite de caixas do plano já foi atingido' do
    subscribe_account_to_plan(account, features: %w[whatsapp_channel whatsapp_unofficial_channel], limits: { 'inboxes' => 1 })
    create(:inbox, account: account)

    create_uazapi_inbox

    expect(response).to have_http_status(:payment_required)
    expect(Whatsapp::UazapiConnectionService).not_to have_received(:new)
  end
end
