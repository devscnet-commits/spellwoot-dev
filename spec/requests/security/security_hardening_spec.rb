require 'rails_helper'

# Testes de segurança do ponto de vista de quem abre o "Inspecionar" do navegador e monta requisições à mão:
# trocar ids para dados de outra conta, subir o próprio papel, mandar tipos trocados, injetar SQL, procurar
# tokens nas respostas e chamar endpoints sem login. Cada teste descreve o ataque e o que o sistema deve fazer.
RSpec.describe 'Segurança: requisições forjadas', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:inbox) { create(:inbox, account: account) }

  let(:other_account) { create(:account) }
  let(:other_admin) { create(:user, account: other_account, role: :administrator) }
  let(:other_inbox) { create(:inbox, account: other_account) }

  def api(path)
    "/api/v1/accounts/#{account.id}#{path}"
  end

  describe 'sem login' do
    it 'rotas da conta recusam requisição sem credencial' do
      %w[/conversations /contacts /inboxes /agents /integration_settings/openai].each do |path|
        get api(path), as: :json
        expect(response).to have_http_status(:unauthorized), path
      end
    end

    it 'token de API inválido é recusado' do
      get api('/conversations'), headers: { api_access_token: 'token-inventado' }, as: :json

      expect(response).to have_http_status(:unauthorized)
    end

    it 'endpoint interno da IA recusa chamada sem o token interno' do
      with_modified_env(INTERNAL_AI_TOKEN: 'segredo-interno') do
        post '/api/internal/ai_execute_tool', params: { ticket_id: 1, ai_agent_id: 1 }, as: :json
      end

      expect(response).to have_http_status(:unauthorized)
    end
  end

  describe 'trocar ids para dados de outra conta' do
    it 'admin não acessa a conta de outro cliente pela URL' do
      get "/api/v1/accounts/#{other_account.id}/conversations", headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:unauthorized)
    end

    it 'admin não lê caixa de outra conta pelo id dentro da própria URL' do
      get api("/inboxes/#{other_inbox.id}"), headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:not_found)
    end

    it 'admin não lê conversa de outra conta pelo número' do
      other_conversation = create(:conversation, account: other_account, inbox: other_inbox)

      get api("/conversations/#{other_conversation.display_id}"), headers: admin.create_new_auth_token, as: :json

      expect(response.body).not_to include(other_conversation.contact.name.to_s) if other_conversation.contact.name.present?
      expect(response).to have_http_status(:not_found)
    end

    it 'admin não lê contato de outra conta' do
      other_contact = create(:contact, account: other_account, email: 'segredo@outra.test')

      get api("/contacts/#{other_contact.id}"), headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:not_found)
      expect(response.body).not_to include('segredo@outra.test')
    end

    it 'admin não liga robô privado de outra conta na própria caixa' do
      other_bot = create(:agent_bot, account: other_account)

      post api("/inboxes/#{inbox.id}/set_agent_bot"), headers: admin.create_new_auth_token,
                                                       params: { agent_bot: other_bot.id }, as: :json

      expect(response).to have_http_status(:not_found)
      expect(inbox.reload.agent_bot).to be_nil
    end
  end

  describe 'subir o próprio papel' do
    it 'agente não se promove a administrador' do
      agent_account_user = agent.account_users.find_by(account: account)

      patch api("/agents/#{agent.id}"), headers: agent.create_new_auth_token, params: { role: 'administrator' }, as: :json

      expect(response).to have_http_status(:unauthorized)
      expect(agent_account_user.reload.role).to eq('agent')
    end

    it 'agente não cria outro usuário' do
      headers = agent.create_new_auth_token

      expect do
        post api('/agents'), headers: headers,
                             params: { name: 'Intruso', email: 'intruso@x.test', role: 'administrator' }, as: :json
      end.not_to change(User, :count)
      expect(response).to have_http_status(:unauthorized)
    end

    it 'agente não lê nem grava credenciais de integração' do
      get api('/integration_settings/openai'), headers: agent.create_new_auth_token, as: :json
      expect(response).to have_http_status(:unauthorized)

      put api('/integration_settings/openai'), headers: agent.create_new_auth_token,
                                               params: { config: { apiKey: 'sk-do-agente' } }, as: :json
      expect(response).to have_http_status(:unauthorized)
      expect(IntegrationSetting.where(account_id: account.id)).to be_empty
    end

    it 'agente não abre relatórios pela API' do
      get "/api/v2/accounts/#{account.id}/reports/summary", headers: agent.create_new_auth_token,
                                                            params: { type: 'account' }, as: :json

      expect(response).to have_http_status(:unauthorized)
    end

    it 'agente não abre caixa da qual não é membro' do
      get api("/inboxes/#{inbox.id}"), headers: agent.create_new_auth_token, as: :json

      expect(response).to have_http_status(:unauthorized)
    end

    it 'perfil não aceita troca de papel nem de conta' do
      put '/api/v1/profile', headers: agent.create_new_auth_token,
                             params: { profile: { name: 'Novo', role: 'administrator', type: 'SuperAdmin' } }, as: :json

      expect(agent.reload.name).to eq('Novo')
      expect(agent.type).to be_nil
      expect(agent.account_users.find_by(account: account).role).to eq('agent')
    end
  end

  describe 'tipos trocados' do
    it 'lista ou objeto no lugar de texto não derruba o servidor' do
      [%w[a b], { '$ne' => 1 }].each do |value|
        patch api("/inboxes/#{inbox.id}"), headers: admin.create_new_auth_token, params: { name: value }, as: :json

        expect(response.status).to be < 500, "name=#{value.inspect} deu #{response.status}"
      end
    end

    it 'id que não é número volta 404, não erro de servidor' do
      get api('/inboxes/1%20OR%201=1'), headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'injeção de SQL' do
    let(:payload) { "' OR 1=1; DROP TABLE users; --" }

    before do
      create(:contact, account: account, name: 'Cliente Local')
      create(:contact, account: other_account, name: 'Cliente Outra Conta', email: 'vazou@outra.test')
    end

    it 'busca de contatos trata o texto como texto (sem vazar outra conta nem apagar tabela)' do
      get api('/contacts/search'), headers: admin.create_new_auth_token, params: { q: payload }, as: :json

      expect(response.status).to be < 500
      expect(response.body).not_to include('vazou@outra.test')
      expect(User.count).to be_positive
    end

    it 'filtro de conversas com atributo forjado não executa SQL' do
      post api('/conversations/filter'), headers: admin.create_new_auth_token,
                                         params: { payload: [{ attribute_key: 'status; DROP TABLE users; --', filter_operator: 'equal_to',
                                                               values: ['open'], query_operator: nil }] }, as: :json

      expect(response.status).to be < 500
      expect(User.count).to be_positive
    end

    it 'ordenação forjada na lista de contatos não executa SQL' do
      get api('/contacts'), headers: admin.create_new_auth_token, params: { sort: 'name; DROP TABLE users; --' }, as: :json

      expect(response.status).to be < 500
      expect(User.count).to be_positive
    end
  end

  describe 'tokens e segredos nas respostas' do
    it 'lista de caixas nunca devolve o token da instância UazAPI (nem para admin)' do
      channel = Channel::Api.create!(account: account, additional_attributes: { 'uazapi_instance_token' => 'tok-instancia-secreto' })
      uazapi_inbox = Inbox.create!(account: account, name: 'WhatsApp', channel: channel)
      create(:inbox_member, user: agent, inbox: uazapi_inbox)

      [agent, admin].each do |user|
        get api('/inboxes'), headers: user.create_new_auth_token, as: :json

        expect(response.body).not_to include('tok-instancia-secreto')
        expect(response.parsed_body['payload'].find { |i| i['id'] == uazapi_inbox.id }['is_uazapi']).to be(true)
      end
    end

    it 'lista de agentes não devolve o token de API de ninguém' do
      get api('/agents'), headers: admin.create_new_auth_token, as: :json

      expect(response.body).not_to include(agent.access_token.token)
      expect(response.body).not_to include(admin.access_token.token)
    end

    it 'agente não recebe segredos do canal (hmac, provider_config) na lista de caixas' do
      api_channel = Channel::Api.create!(account: account)
      api_inbox = Inbox.create!(account: account, name: 'API', channel: api_channel)
      create(:inbox_member, user: agent, inbox: api_inbox)

      get api('/inboxes'), headers: agent.create_new_auth_token, as: :json

      expect(response.body).not_to include(api_channel.hmac_token)
      expect(response.body).not_to include(api_channel.secret.to_s) if api_channel.secret.present?
    end

    it 'perfil devolve só o token do próprio usuário' do
      get '/api/v1/profile', headers: agent.create_new_auth_token, as: :json

      expect(response.parsed_body['access_token']).to eq(agent.access_token.token)
      expect(response.body).not_to include(admin.access_token.token)
    end
  end

  describe 'consulta pública' do
    it 'widget não expõe e-mail nem token dos agentes' do
      web_widget = create(:channel_widget, account: account)
      create(:inbox_member, user: agent, inbox: web_widget.inbox)

      get '/api/v1/widget/inbox_members', params: { website_token: web_widget.website_token }

      expect(response.body).not_to include(agent.email)
      expect(response.body).not_to include(agent.access_token.token)
    end

    it 'API pública da caixa não expõe dados de outros contatos' do
      api_inbox = create(:channel_api, account: account).inbox
      create(:contact, account: account, email: 'outro-contato@x.test')

      get "/public/api/v1/inboxes/#{api_inbox.channel.identifier}"

      expect(response.body).not_to include('outro-contato@x.test')
      expect(response.body).not_to include(api_inbox.channel.hmac_token)
    end
  end
end
