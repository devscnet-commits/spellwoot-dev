require 'rails_helper'

# Caminho LEGADO, paralelo ao Hub: AICTAModal.vue grava { app_id: 'openai', settings: { api_key } }
# em integrations_hooks. Só `access_token` é criptografado no model; `settings` (jsonb) não é. E o
# jbuilder despeja settings cru para administrador, sem máscara nenhuma.
RSpec.describe 'Chave no caminho legado de integrations/hooks' do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agente) { create(:user, account: account, role: :agent) }
  let(:chave) { 'sk-LEGADO-no-hook-1234567890' }

  # A listagem vem embrulhada em `payload`, e o hook fica aninhado dentro do app a que pertence.
  def openai_hook(response)
    response.parsed_body['payload'].find { |app| app['id'] == 'openai' }['hooks'].first
  end

  before do
    post "/api/v1/accounts/#{account.id}/integrations/hooks",
         params: { hook: { app_id: 'openai', settings: { api_key: chave } } },
         headers: admin.create_new_auth_token
  end

  it 'não devolve a chave em texto puro para o administrador' do
    get "/api/v1/accounts/#{account.id}/integrations/apps", headers: admin.create_new_auth_token

    expect(response).to have_http_status(:success)
    expect(response.body).not_to include(chave)
  end

  it 'mascara mantendo prefixo e sufixo, para o admin reconhecer qual chave cadastrou' do
    get "/api/v1/accounts/#{account.id}/integrations/apps", headers: admin.create_new_auth_token

    expect(openai_hook(response)['settings']['api_key']).to eq("sk-L#{'*' * 20}890")
  end

  it 'não devolve settings nenhum para agente comum' do
    get "/api/v1/accounts/#{account.id}/integrations/apps", headers: agente.create_new_auth_token

    expect(response.body).not_to include(chave)
    expect(openai_hook(response)).not_to have_key('settings')
  end

  it 'preserva os campos não-secretos do mesmo hash' do
    Integrations::Hook.find_by(account_id: account.id, app_id: 'openai')
                      .update!(settings: { 'api_key' => chave, 'label_suggestion' => true })

    get "/api/v1/accounts/#{account.id}/integrations/apps", headers: admin.create_new_auth_token

    settings = openai_hook(response)['settings']
    expect(settings['label_suggestion']).to be(true)
    expect(settings['api_key']).not_to eq(chave)
  end
end
