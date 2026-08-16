require 'rails_helper'

RSpec.describe Ai::IntegrationConnector do
  let(:account) { create(:account) }

  def link(endpoint:, method: 'POST', retry_count: 0)
    Ai::IntegrationLink.create!(account: account, name: 'ERP', kind: 'webhook', status: 'active',
                                endpoint: endpoint, http_method: method, retry_count: retry_count)
  end

  before do
    allow(Resolv).to receive(:getaddresses).and_call_original
    allow(Resolv).to receive(:getaddresses).with('erp.example.com').and_return(['93.184.216.34'])
  end

  it 'dispara para um endpoint público e devolve status + body parseado' do
    stub_request(:post, 'http://erp.example.com/consulta')
      .to_return(status: 200, body: '{"saldo":10}', headers: { 'Content-Type' => 'application/json' })

    result = described_class.call(link(endpoint: 'http://erp.example.com/consulta'), input: { 'cpf' => '1' })

    expect(result['status']).to eq(200)
    expect(result['body']).to eq({ 'saldo' => 10 })
  end

  it 'trata um status HTTP de erro (404/500...) como falha, e RE-TENTA como qualquer outra falha' do
    stub_request(:post, 'http://erp.example.com/consulta')
      .to_return(status: 500, body: 'internal error')

    expect do
      described_class.call(link(endpoint: 'http://erp.example.com/consulta', retry_count: 2), input: {})
    end.to raise_error(RuntimeError, /falhou.*HTTP 500/)

    expect(WebMock).to have_requested(:post, 'http://erp.example.com/consulta').times(3)
  end

  it 'REJEITA um endpoint que aponta para o metadata endpoint (SSRF) com erro claro' do
    expect do
      described_class.call(link(endpoint: 'http://169.254.169.254/latest/meta-data/'), input: {})
    end.to raise_error(RuntimeError, /bloqueada por segurança/)
  end

  it 'NÃO re-tenta uma URL bloqueada (falha imediata, mesmo com retry_count > 0)' do
    connector = described_class
    allow(connector).to receive(:request).and_call_original

    expect do
      connector.call(link(endpoint: 'http://10.0.0.9/erp', retry_count: 3), input: {})
    end.to raise_error(RuntimeError, /bloqueada por segurança/)

    # request é chamado uma única vez — a URL barrada não entra no laço de retry.
    expect(connector).to have_received(:request).once
  end
end
