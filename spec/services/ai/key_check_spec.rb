require 'rails_helper'

# Ai::KeyCheck responde duas perguntas que antes não tinham resposta confiável: QUAL chave os módulos
# de IA usam de fato para esta conta, e se ela funciona de verdade. O teste de conexão anterior lia a
# cascata conta→global→ENV e batia em GET /v1/models — podia validar a chave do SERVIDOR e reportar
# sucesso para uma conta sem chave nenhuma, e dava 200 também para chave sem crédito.
RSpec.describe Ai::KeyCheck do
  let(:account) { create(:account) }

  def account_row!(key: 'sk-da-conta', enabled: true, model: nil)
    config = {}
    config['apiKey'] = key if key
    config['model'] = model if model
    IntegrationSetting.create!(account_id: account.id, provider: 'openai', enabled: enabled, config: config.to_json)
  end

  def global_row!(key: 'sk-GLOBAL-do-hub')
    IntegrationSetting.create!(account_id: nil, provider: 'openai', enabled: true,
                               config: { 'apiKey' => key }.to_json)
  end

  def platform_key!(key: 'sk-PLATAFORMA')
    create(:installation_config, name: 'CAPTAIN_OPEN_AI_API_KEY', value: key)
  end

  def stub_probe(status: 200, body: { id: 'resp_1' })
    stub_request(:post, described_class::RESPONSES_URL)
      .to_return(status: status, body: body.to_json, headers: { 'Content-Type' => 'application/json' })
  end

  def error_body(message, code)
    { error: { message: message, code: code } }
  end

  def perform
    described_class.new(account: account).perform
  end

  def status
    described_class.new(account: account).status
  end

  describe '#status (sem rede)' do
    it 'reconhece a chave própria da conta' do
      enable_byok!(account)
      account_row!(key: 'sk-da-conta-1234567')

      expect(status).to include(key_source: 'account', key_reason: 'account_key', account_id: account.id)
    end

    it 'sem linha da conta: roda na plataforma e diz que não há chave cadastrada' do
      enable_byok!(account)

      expect(status).to include(key_source: 'platform', key_reason: 'not_configured')
    end

    it 'sem a feature: a linha do Hub é ignorada (fail-safe de linha órfã)' do
      account_row!(key: 'sk-orfa')

      expect(status).to include(key_source: 'platform', key_reason: 'feature_disabled')
    end

    it 'linha desativada: não usa a chave e explica que a integração está desligada' do
      enable_byok!(account)
      account_row!(key: 'sk-da-conta', enabled: false)

      expect(status).to include(key_source: 'platform', key_reason: 'provider_disabled')
    end

    it 'linha salva sem apiKey: distingue de "nunca configurou"' do
      enable_byok!(account)
      account_row!(key: nil, model: 'gpt-4o')

      expect(status).to include(key_source: 'platform', key_reason: 'key_missing')
    end

    # A tela é do admin do CLIENTE: um preview da chave da plataforma entregaria pedaços de um
    # segredo do servidor a todo tenant que abrisse a aba.
    it 'só mostra preview da chave DA CONTA, nunca da plataforma' do
      platform_key!
      enable_byok!(account)

      expect(status[:key_preview]).to be_nil

      account_row!(key: 'sk-abcdefghijklmnop')
      expect(status[:key_preview]).to eq("sk-a#{'*' * 12}nop")
    end

    it 'traz o saldo do plano só quando quem paga é a plataforma' do
      AiCreditBalance.create!(account_id: account.id, plan_credits: 7, extra_credits: 3)

      expect(status[:credits]).to eq({ total: 10, enforced: true })

      enable_byok!(account)
      account_row!(key: 'sk-da-conta')
      expect(status[:credits]).to be_nil
    end
  end

  describe '#perform (chamada real stubada)' do
    # A REGRESSÃO CENTRAL: a cascata antiga devolvia global/ENV como se fosse a chave da conta, e era
    # assim que o orquestrador voltava a rodar na chave do backend sem ninguém perceber.
    it 'NÃO usa a linha global do Hub para uma conta sem chave própria' do
      global_row!(key: 'sk-GLOBAL-do-hub')
      platform_key!(key: 'sk-PLATAFORMA')
      enable_byok!(account)
      stub_probe

      result = perform

      expect(WebMock).to have_requested(:post, described_class::RESPONSES_URL)
        .with(headers: { 'Authorization' => 'Bearer sk-PLATAFORMA' })
      expect(result).to include(key_source: 'platform', key_reason: 'not_configured')
    end

    it 'usa a chave DA CONTA quando ela existe' do
      platform_key!(key: 'sk-PLATAFORMA')
      enable_byok!(account)
      account_row!(key: 'sk-da-conta')
      stub_probe

      perform

      expect(WebMock).to have_requested(:post, described_class::RESPONSES_URL)
        .with(headers: { 'Authorization' => 'Bearer sk-da-conta' })
    end

    it 'verde só quando a chamada real passou NA chave da conta' do
      enable_byok!(account)
      account_row!(key: 'sk-da-conta')
      stub_probe

      expect(perform).to include(ok: true, level: 'success', code: 'account_key_valid')
    end

    it 'âmbar quando a chamada passou, mas na chave da plataforma' do
      platform_key!
      stub_probe

      result = perform

      expect(result).to include(ok: true, level: 'warning', code: 'platform_key_valid')
      expect(result[:message]).to include('PLATAFORMA')
    end

    it 'chave revogada: invalid_key, não uma falha genérica' do
      enable_byok!(account)
      account_row!(key: 'sk-revogada')
      stub_probe(status: 401, body: error_body('Incorrect API key provided', 'invalid_api_key'))

      expect(perform).to include(ok: false, level: 'error', code: 'invalid_key')
    end

    # O caso que o GET /v1/models antigo NUNCA pegava: chave válida lista modelos normalmente mesmo
    # sem crédito nenhum, e o teste dava verde enquanto o atendimento real falhava.
    it 'chave válida sem cota: insufficient_quota' do
      enable_byok!(account)
      account_row!(key: 'sk-sem-cota')
      stub_probe(status: 429, body: error_body('You exceeded your current quota', 'insufficient_quota'))

      result = perform

      expect(result).to include(ok: false, code: 'insufficient_quota')
      expect(result[:message]).to include('sem crédito')
    end

    it 'modelo inexistente para a chave: model_not_found' do
      platform_key!
      stub_probe(status: 404, body: error_body('The model does not exist', 'model_not_found'))

      expect(perform).to include(ok: false, code: 'model_not_found')
    end

    it 'falha de rede não vira exceção: network_error' do
      platform_key!
      stub_request(:post, described_class::RESPONSES_URL).to_timeout

      expect(perform).to include(ok: false, level: 'error', code: 'network_error')
    end

    it 'sonda com o modelo configurado no Hub da conta' do
      enable_byok!(account)
      account_row!(key: 'sk-da-conta', model: 'gpt-4o')
      stub_probe

      expect(perform[:model]).to eq('gpt-4o')
      expect(WebMock).to have_requested(:post, described_class::RESPONSES_URL)
        .with { |req| JSON.parse(req.body)['model'] == 'gpt-4o' }
    end

    it 'sem modelo no Hub, sonda com o modelo do perfil de operação (o que o turno real usa)' do
      Ai::OperationProfile.create!(account: account, name: 'padrão',
                                   supervisor_provider: 'openai', supervisor_model: 'gpt-4.1')
      platform_key!
      stub_probe

      expect(perform[:model]).to eq('gpt-4.1')
    end

    # with_modified_env porque a chave da plataforma cai no ENV quando não há InstallationConfig:
    # num ambiente onde OPENAI_API_KEY está setada, este caso simplesmente não existiria.
    it 'sem chave em lugar nenhum: no_key_available, sem tentar a rede' do
      with_modified_env(OPENAI_API_KEY: nil) do
        expect(perform).to include(ok: false, code: 'no_key_available')
      end

      expect(WebMock).not_to have_requested(:post, described_class::RESPONSES_URL)
    end
  end
end
