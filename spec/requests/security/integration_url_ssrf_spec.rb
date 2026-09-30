require 'rails_helper'

# Endereço de servidor digitado em APIs & Credenciais (UazAPI, Evolution, webhooks de n8n/Bitrix) vira destino
# de chamadas do nosso servidor. Endereço interno transformaria o formulário em porta para a rede interna (SSRF).
RSpec.describe 'APIs & Credenciais: só endereço público', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }

  def save(provider, config)
    put "/api/v1/accounts/#{account.id}/integration_settings/#{provider}", headers: admin.create_new_auth_token,
                                                                            params: { config: config }, as: :json
  end

  before do
    allow(Resolv).to receive(:getaddresses).and_call_original
    allow(Resolv).to receive(:getaddresses).with('conexiia.uazapi.com').and_return(['104.21.10.10'])
    allow(Resolv).to receive(:getaddresses).with('interno.empresa.test').and_return(['10.0.0.8'])
    allow(Resolv).to receive(:getaddresses).with('nao-existe.test').and_return([])
  end

  it 'aceita o servidor UazAPI público' do
    save('uazapi', { apiUrl: 'https://conexiia.uazapi.com', token: 'admin-token' })

    expect(response).to have_http_status(:success)
    expect(IntegrationSetting.find_by(account_id: account.id, provider: 'uazapi').config_hash['apiUrl']).to eq('https://conexiia.uazapi.com')
  end

  {
    'localhost' => 'http://127.0.0.1:3000',
    'metadados da nuvem' => 'http://169.254.169.254/latest/meta-data',
    'rede interna (IP)' => 'http://10.0.0.5:8080',
    'rede interna (nome que resolve para IP privado)' => 'http://interno.empresa.test',
    'IPv6 local' => 'http://[::1]:5432',
    'protocolo que não é http' => 'file:///etc/passwd',
    'host que não resolve' => 'https://nao-existe.test'
  }.each do |label, url|
    it "recusa #{label}" do
      save('uazapi', { apiUrl: url, token: 'admin-token' })

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['error']).to include('apiUrl')
      expect(IntegrationSetting.find_by(account_id: account.id, provider: 'uazapi')).to be_nil
    end
  end

  it 'vale para qualquer campo de URL (webhook do n8n, Evolution)' do
    save('n8n', { webhookUrl: 'http://127.0.0.1:5678/webhook' })
    expect(response).to have_http_status(:unprocessable_entity)

    save('evolution_api', { apiUrl: 'http://10.1.1.1', apiKey: 'k' })
    expect(response).to have_http_status(:unprocessable_entity)
  end

  it 'campos que não são URL seguem livres' do
    save('uazapi', { token: 'so-o-token' })

    expect(response).to have_http_status(:success)
  end
end
