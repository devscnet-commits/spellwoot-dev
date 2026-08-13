require 'rails_helper'

# BYOK (billing Fase 3): validação real da chave própria dos 4 providers de LLM. Cada provider bate no
# seu endpoint de listagem/validação; 401/403 = chave inválida, sucesso = chave aceita.
RSpec.describe IntegrationSettingsService do
  describe '.test_connection (providers BYOK)' do
    let(:cases) do
      {
        'anthropic'  => 'https://api.anthropic.com/v1/models',
        'gemini'     => %r{https://generativelanguage\.googleapis\.com/v1beta/models},
        'groq'       => 'https://api.groq.com/openai/v1/models',
        'openrouter' => 'https://openrouter.ai/api/v1/key'
      }
    end

    it 'aceita a chave quando o provider responde 200' do
      cases.each do |provider, endpoint|
        stub_request(:get, endpoint).to_return(status: 200, body: '{"data":[]}', headers: { 'Content-Type' => 'application/json' })
        result = described_class.test_connection(provider, { 'apiKey' => 'valid-key' })
        expect(result[:ok]).to be(true), "esperava ok para #{provider}, veio #{result.inspect}"
      end
    end

    it 'rejeita a chave quando o provider responde 401' do
      cases.each do |provider, endpoint|
        stub_request(:get, endpoint).to_return(status: 401, body: '{"error":"unauthorized"}', headers: { 'Content-Type' => 'application/json' })
        result = described_class.test_connection(provider, { 'apiKey' => 'bad-key' })
        expect(result[:ok]).to be(false), "esperava falha para #{provider}, veio #{result.inspect}"
        expect(result[:message]).to match(/inválida ou revogada/)
      end
    end

    it 'rejeita antes de qualquer chamada quando a apiKey está em branco' do
      cases.each_key do |provider|
        result = described_class.test_connection(provider, {})
        expect(result[:ok]).to be(false)
        expect(result[:message]).to match(/não configurada/)
      end
      # nenhuma requisição externa foi feita (WebMock nega net por padrão; sem stub, um GET estouraria)
    end
  end
end
