require 'rails_helper'

# Verificação de SEGURANÇA: a chave da conta pode ser recuperada olhando a resposta HTTP crua?
# Mascarar no front não vale nada se o texto puro viaja no JSON — é isso que este arquivo decide.
RSpec.describe 'Exposição da chave de IA nas requisições' do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agente) { create(:user, account: account, role: :agent) }
  let(:chave) { 'sk-proj-SEGREDOabcdefghijklmnop1234567890XYZ' }

  before do
    IntegrationSetting.create!(account_id: account.id, provider: 'openai', enabled: true,
                               config: { 'apiKey' => chave, 'model' => 'gpt-4.1-mini' }.to_json)
  end

  def corpo_cru
    response.body
  end

  it 'GET nunca devolve a chave em texto puro' do
    get "/api/v1/accounts/#{account.id}/integration_settings/openai", headers: admin.create_new_auth_token

    expect(response).to have_http_status(:success)
    puts "\n--- config.apiKey devolvido: #{response.parsed_body.dig('config', 'apiKey').inspect}"
    puts "--- ai_key_status.key_preview: #{response.parsed_body.dig('ai_key_status', 'key_preview').inspect}"
    expect(corpo_cru).not_to include(chave)
    expect(corpo_cru).not_to include('SEGREDOabcdefghijklmnop')
  end

  it 'PUT não ecoa a chave de volta em texto puro' do
    put "/api/v1/accounts/#{account.id}/integration_settings/openai",
        params: { config: { model: 'gpt-4.1' }, enabled: true }, headers: admin.create_new_auth_token

    expect(corpo_cru).not_to include(chave)
  end

  it 'um AGENTE comum não alcança o endpoint' do
    get "/api/v1/accounts/#{account.id}/integration_settings/openai", headers: agente.create_new_auth_token

    puts "--- agente comum recebe: #{response.status}"
    expect(response).not_to have_http_status(:success)
    expect(corpo_cru).not_to include(chave)
  end

  it 'admin de OUTRA conta não alcança esta conta' do
    outra = create(:account)
    intruso = create(:user, account: outra, role: :administrator)

    get "/api/v1/accounts/#{account.id}/integration_settings/openai", headers: intruso.create_new_auth_token

    puts "--- admin de outra conta recebe: #{response.status}"
    expect(response).not_to have_http_status(:success)
    expect(corpo_cru).not_to include(chave)
  end

  it 'o teste de conexão não devolve a chave na mensagem' do
    stub_request(:post, Ai::KeyCheck::RESPONSES_URL).to_return(status: 200, body: '{"id":"resp_1"}',
                                                               headers: { 'Content-Type' => 'application/json' })
    post "/api/v1/accounts/#{account.id}/integration_settings/openai/test_connection",
         headers: admin.create_new_auth_token

    puts "--- test_connection: #{response.parsed_body['message'].to_s[0, 120]}"
    expect(corpo_cru).not_to include(chave)
  end

  it 'a chave do SERVIDOR (ENV) aparece mascarada para o admin do cliente — cascata de exibição' do
    IntegrationSetting.find_by(account_id: account.id, provider: 'openai').destroy!
    with_modified_env(OPENAI_API_KEY: 'sk-DO-SERVIDOR-nunca-do-cliente-FIM') do
      get "/api/v1/accounts/#{account.id}/integration_settings/openai", headers: admin.create_new_auth_token

      puts "--- sem chave própria, o que o cliente vê: #{response.parsed_body.dig('config', 'apiKey').inspect}"
      puts "--- e a origem declarada: #{response.parsed_body.dig('sources', 'apiKey').inspect}"
      expect(corpo_cru).not_to include('sk-DO-SERVIDOR-nunca-do-cliente-FIM')
    end
  end
end
