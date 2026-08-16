require 'rails_helper'

RSpec.describe Ai::WebhookRunner do
  before do
    allow(Resolv).to receive(:getaddresses).and_call_original
    allow(Resolv).to receive(:getaddresses).with('hook.example.com').and_return(['93.184.216.34'])
  end

  describe '.call' do
    it 'dispara para uma URL pública e devolve status + body parseado' do
      stub_request(:post, 'http://hook.example.com/notify')
        .to_return(status: 200, body: '{"received":true}', headers: { 'Content-Type' => 'application/json' })

      result = described_class.call({ 'url' => 'http://hook.example.com/notify', 'method' => 'POST' },
                                    input: { 'nome' => 'Ana' })

      expect(result['status']).to eq(200)
      expect(result['body']).to eq({ 'received' => true })
    end

    it 'trata um status HTTP de erro (404/500...) como falha, mesmo sem exceção de rede' do
      stub_request(:post, 'http://hook.example.com/notify')
        .to_return(status: 404, body: '<html>Página não encontrada</html>')

      expect do
        described_class.call({ 'url' => 'http://hook.example.com/notify', 'method' => 'POST' }, input: {})
      end.to raise_error(RuntimeError, /HTTP 404/)
    end

    it 'REJEITA uma URL que aponta para o metadata endpoint (SSRF) com erro claro, sem stack trace' do
      expect do
        described_class.call({ 'url' => 'http://169.254.169.254/latest/meta-data/', 'method' => 'POST' },
                             input: {})
      end.to raise_error(RuntimeError, /bloqueado por segurança/)
    end

    it 'REJEITA uma URL de rede interna (IP privado)' do
      expect do
        described_class.call({ 'url' => 'http://10.1.2.3/internal', 'method' => 'GET' }, input: {})
      end.to raise_error(RuntimeError, /bloqueado por segurança/)
    end
  end
end
