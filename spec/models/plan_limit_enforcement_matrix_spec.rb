require 'rails_helper'

# Matriz de travas de LIMITE do plano: para cada limite contado (agentes de IA, caixas, usuários), TODO caminho
# de criação é exercitado com o plano cheio (tem que bloquear) — tela/API, duplicar, convite em massa,
# integração (Platform API), serviço interno e gravação direta (console/job). Achado ao vivo que motivou:
# plano com 10 agentes de IA, "Duplicar" criou o 11º porque só o POST de criação checava o limite.
#
# Regra: a trava vive no MODELO (PlanLimited). Um caminho novo de criação já nasce travado — este spec é a rede
# para quem remover a trava de um modelo ou criar um limite novo sem ela.
RSpec.describe 'Travas de limite do plano (todos os caminhos de criação)', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:headers) { admin.create_new_auth_token }
  let(:profile) do
    Ai::OperationProfile.create!(account_id: account.id, name: 'p', supervisor_provider: 'openai', supervisor_model: 'gpt-4.1-mini')
  end

  def new_ai_agent(name = "IA #{SecureRandom.hex(3)}")
    Ai::Agent.create!(account: account, name: name, status: 'active', ai_operation_profile_id: profile.id)
  end

  def fill_plan(key, max, overflow: nil)
    plan = subscribe_account_to_plan(account, features: Plan::MANAGED_FEATURE_KEYS, limits: { key => max })
    plan.plan_limits.find_by(key: key).update!(overflow_behavior: overflow) if overflow
    RequestStore.clear! # como em produção: cada requisição lê o plano do zero
    plan
  end

  def expect_blocked
    expect(response).to have_http_status(:payment_required)
    expect(response.parsed_body['error']).to match(/Limite de .* do seu plano atingido/)
  end

  describe 'agentes de IA (ai_agents)' do
    let!(:existing) { new_ai_agent('Maya') }

    before { fill_plan('ai_agents', 1) }

    it 'POST criar: bloqueia' do
      expect do
        post "/api/v1/accounts/#{account.id}/ai_agents", headers: headers, params: { ai_agent: { name: 'Nova', ai_operation_profile_id: profile.id } }, as: :json
      end.not_to change(Ai::Agent, :count)
      expect_blocked
    end

    it 'Duplicar: bloqueia (o caso real — antes criava o 11º num plano de 10)' do
      expect do
        post "/api/v1/accounts/#{account.id}/ai_agents/#{existing.id}/duplicate", headers: headers, as: :json
      end.not_to change(Ai::Agent, :count)
      expect_blocked
    end

    it 'gravação direta (console/job/importação): bloqueia' do
      expect { new_ai_agent }.to raise_error(CustomExceptions::Plan::LimitExceeded)
      expect(Ai::Agent.where(account_id: account.id).count).to eq(1)
    end
  end

  describe 'caixas de entrada (inboxes)' do
    before do
      create(:inbox, account: account)
      fill_plan('inboxes', 1)
    end

    it 'POST criar caixa: bloqueia' do
      expect do
        post "/api/v1/accounts/#{account.id}/inboxes", headers: headers,
                                                        params: { name: 'Nova', channel: { type: 'api' } }, as: :json
      end.not_to change(Inbox, :count)
      expect_blocked
    end

    it 'gravação direta (integrações de canal, callbacks OAuth, jobs, console): bloqueia' do
      expect { create(:inbox, account: account) }.to raise_error(CustomExceptions::Plan::LimitExceeded)
    end

    it 'caixa interna de teste dos agentes de IA: não ocupa vaga nem é bloqueada' do
      test_inbox = account.inboxes.create!(name: Inbox::AI_TEST_INBOX_NAME, channel: Channel::Api.create!(account: account))

      expect(test_inbox).to be_persisted
      expect(Billing::LimitUsage.current_count(account, 'inboxes')).to eq(1)
    end
  end

  describe 'usuários (users)' do
    let(:outsider) { create(:user) }

    before do
      admin
      fill_plan('users', 1)
    end

    it 'POST convidar agente: bloqueia' do
      expect do
        post "/api/v1/accounts/#{account.id}/agents", headers: headers,
                                                       params: { name: 'Novo', email: 'novo@exemplo.com', role: 'agent' }, as: :json
      end.not_to change(AccountUser, :count)
      expect_blocked
    end

    it 'convite em massa: bloqueia' do
      expect do
        post "/api/v1/accounts/#{account.id}/agents/bulk_create", headers: headers,
                                                                   params: { emails: ['a@exemplo.com'] }, as: :json
      end.not_to change(AccountUser, :count)
      expect_blocked
    end

    it 'Platform API (integração que adiciona usuário à conta): bloqueia' do
      platform_app = create(:platform_app)
      create(:platform_app_permissible, platform_app: platform_app, permissible: account)

      expect do
        post "/platform/api/v1/accounts/#{account.id}/account_users",
             params: { user_id: outsider.id, role: 'agent' },
             headers: { api_access_token: platform_app.access_token.token }, as: :json
      end.not_to change(AccountUser, :count)
      expect_blocked
    end

    it 'serviço interno (AgentBuilder) e gravação direta: bloqueiam' do
      expect do
        AgentBuilder.new(email: 'b@exemplo.com', name: 'B', inviter: admin, account: account, role: 'agent').perform
      end.to raise_error(CustomExceptions::Plan::LimitExceeded)
      expect { AccountUser.create!(account: account, user: outsider, role: :agent) }
        .to raise_error(CustomExceptions::Plan::LimitExceeded)
    end
  end

  describe 'quando NÃO bloqueia' do
    before { new_ai_agent('Maya') }

    it 'dentro do limite' do
      fill_plan('ai_agents', 2)

      expect { new_ai_agent }.not_to raise_error
    end

    it 'limite em branco (ilimitado)' do
      fill_plan('ai_agents', nil)

      expect { 3.times { new_ai_agent } }.not_to raise_error
    end

    it '"Permitir e cobrar excedente" (paid_overage)' do
      fill_plan('ai_agents', 1, overflow: :paid_overage)

      expect { new_ai_agent }.not_to raise_error
    end

    it 'conta sem plano' do
      expect { new_ai_agent }.not_to raise_error
    end

    it 'editar um registro existente nunca é barrado pelo limite' do
      fill_plan('ai_agents', 1)
      agent = Ai::Agent.find_by(account_id: account.id)

      expect { agent.update!(name: 'Maya 2') }.not_to raise_error
    end
  end
end
