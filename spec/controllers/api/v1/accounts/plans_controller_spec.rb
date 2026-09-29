require 'rails_helper'

# Cobertura que faltava desde a criação da tela: `resource :plan` (routes.rb) roteia pelo nome
# PLURALIZADO por convenção do Rails — `Api::V1::Accounts::PlansController` — mesmo sendo um recurso
# singular na URL. O controller vivia em `plan_controller.rb` como `PlanController` (singular), então
# TODA chamada a este endpoint batia em "uninitialized constant PlansController" e o Rails respondia
# 404 genérico, nunca o corpo que o controller monta. Nenhum spec chamava a rota via HTTP antes deste
# arquivo, por isso passou despercebido.
RSpec.describe 'Account Plan API', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }

  describe 'GET /api/v1/accounts/{account.id}/plan/limits' do
    it 'resolve para o controller certo (regressão do bug de nome singular/plural)' do
      route = Rails.application.routes.recognize_path(
        "/api/v1/accounts/#{account.id}/plan/limits", method: :get
      )

      expect(route[:controller]).to eq('api/v1/accounts/plans')
    end

    context 'when a conta não tem assinatura ativa' do
      it 'devolve 404 com o erro do controller' do
        get "/api/v1/accounts/#{account.id}/plan/limits", headers: admin.create_new_auth_token, as: :json

        expect(response).to have_http_status(:not_found)
        expect(response.parsed_body['error']).to eq('No active subscription')
      end
    end

    context 'when a conta tem uma assinatura ativa' do
      it 'devolve o plano, os créditos de IA e os limites' do
        plan = subscribe_account_to_plan(account, ai_credits: 1000, limits: { 'users' => 5 })

        get "/api/v1/accounts/#{account.id}/plan/limits", headers: admin.create_new_auth_token, as: :json

        expect(response).to have_http_status(:ok)
        body = response.parsed_body
        expect(body['plan']['id']).to eq(plan.id)
        expect(body['plan']['name']).to eq(plan.name)
        expect(body['ai_credit_balance']['plan_credits']).to eq(1000)
        expect(body['limits'].find { |l| l['key'] == 'users' }['max_value']).to eq(5)
        expect(body['subscription']['status']).to eq('active')
      end
    end

    describe 'ai_key (chave própria x créditos Conexiia)' do
      def fetch_ai_key
        get "/api/v1/accounts/#{account.id}/plan/limits", headers: admin.create_new_auth_token, as: :json
        response.parsed_body['ai_key']
      end

      it 'plano sem chave própria: não permite e não usa' do
        subscribe_account_to_plan(account)

        expect(fetch_ai_key).to include('own_key_allowed' => false, 'using_own_key' => false)
      end

      it 'plano com chave própria mas sem chave cadastrada: permite, ainda consome créditos' do
        subscribe_account_to_plan(account, features: ['custom_llm_api_key'])

        expect(fetch_ai_key).to include('own_key_allowed' => true, 'using_own_key' => false)
      end

      it 'plano com chave própria e chave cadastrada: usando a própria chave' do
        subscribe_account_to_plan(account, features: ['custom_llm_api_key'])
        IntegrationSetting.create!(account_id: account.id, provider: 'openai', enabled: true,
                                   config: { apiKey: 'sk-conta-teste' }.to_json)

        expect(fetch_ai_key).to include('own_key_allowed' => true, 'using_own_key' => true)
      end

      it 'conta as respostas da IA enviadas no ciclo atual (sem chamar o provedor)' do
        subscribe_account_to_plan(account, features: ['custom_llm_api_key'])
        2.times { Ai::Event.create!(account_id: account.id, event_type: 'reply.sent') }
        Ai::Event.create!(account_id: account.id, event_type: 'reply.intended')
        Ai::Event.create!(account_id: account.id, event_type: 'reply.sent', created_at: 2.days.ago)
        Ai::Event.create!(account_id: create(:account).id, event_type: 'reply.sent')

        expect(fetch_ai_key['replies_this_cycle']).to eq(2)
      end

      it 'chave cadastrada NÃO vale se o plano não permite chave própria' do
        subscribe_account_to_plan(account)
        IntegrationSetting.create!(account_id: account.id, provider: 'openai', enabled: true,
                                   config: { apiKey: 'sk-conta-teste' }.to_json)

        expect(fetch_ai_key).to include('own_key_allowed' => false, 'using_own_key' => false)
      end
    end

    it 'exige autenticação' do
      get "/api/v1/accounts/#{account.id}/plan/limits"

      expect(response).to have_http_status(:unauthorized)
    end
  end

  # O cliente não troca de plano sozinho: o plano só muda depois do pagamento confirmado (hoje pelo Super
  # Admin). Antes existia POST /plan/upgrade, que trocava na hora, sem pagamento — pela tela ou direto
  # pela API.
  describe 'upgrade sem pagamento' do
    it 'não existe mais rota para o cliente trocar o próprio plano' do
      expect { Rails.application.routes.recognize_path("/api/v1/accounts/#{account.id}/plan/upgrade", method: :post) }
        .to raise_error(ActionController::RoutingError)
    end
  end

  describe 'upgrade_contact (WhatsApp da Conexiia para pedidos de upgrade)' do
    before do
      subscribe_account_to_plan(account)
      GlobalConfig.clear_cache
    end

    def fetch_contact
      get "/api/v1/accounts/#{account.id}/plan/limits", headers: admin.create_new_auth_token, as: :json
      response.parsed_body['upgrade_contact']
    end

    it 'devolve só os dígitos do número configurado no Super Admin' do
      InstallationConfig.create!(name: 'PLAN_UPGRADE_WHATSAPP_NUMBER', value: '+55 (49) 99999-0000', locked: false)
      GlobalConfig.clear_cache

      expect(fetch_contact).to include('whatsapp_number' => '5549999990000')
    end

    it 'sem número configurado, devolve nil' do
      expect(fetch_contact).to include('whatsapp_number' => nil, 'email_request' => false)
    end
  end

  # Sem WhatsApp de upgrade configurado, o cliente ainda consegue pedir: a equipe Conexiia recebe por e-mail.
  # O plano NÃO muda — só depois do pagamento confirmado, pelo Super Admin.
  describe 'POST /api/v1/accounts/{account.id}/plan/upgrade_request' do
    let(:agent) { create(:user, account: account, role: :agent) }
    let!(:start_plan) { subscribe_account_to_plan(account).tap { |p| p.update!(slug: 'start', name: 'START') } }
    let!(:plus) { Plan.create!(name: 'PLUS', slug: 'plus', visible_to_new_subscribers: true) }

    def request_upgrade(slug, user: admin)
      post "/api/v1/accounts/#{account.id}/plan/upgrade_request",
           params: { plan_slug: slug }, headers: user.create_new_auth_token, as: :json
    end

    before do
      ActiveJob::Base.queue_adapter = :test
      InstallationConfig.create!(name: 'CHATWOOT_INSTANCE_ADMIN_EMAIL', value: 'equipe@conexiia.test', locked: false)
      GlobalConfig.clear_cache
    end

    it 'avisa a equipe por e-mail e NÃO muda o plano' do
      expect { request_upgrade('plus') }
        .to have_enqueued_mail(AdministratorNotifications::PlanUpgradeMailer, :new_request)

      expect(response).to have_http_status(:ok)
      expect(account.reload.subscriptions.current.first.plan).to eq(start_plan)
    end

    it 'recusa plano que não é upgrade disponível para a conta' do
      request_upgrade('start')

      expect(response).to have_http_status(:unprocessable_entity)
    end

    it 'sem e-mail da equipe configurado, avisa que não há contato' do
      InstallationConfig.find_by(name: 'CHATWOOT_INSTANCE_ADMIN_EMAIL').destroy!
      GlobalConfig.clear_cache

      request_upgrade('plus')

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['error']).to eq('no_contact')
    end

    it 'agente não pode pedir upgrade' do
      request_upgrade('plus', user: agent)

      expect(response).to have_http_status(:forbidden)
    end

    it 'o e-mail leva conta, plano atual e plano desejado' do
      mailer = AdministratorNotifications::PlanUpgradeMailer.new
      allow(AdministratorNotifications::PlanUpgradeMailer).to receive(:new).and_return(mailer)
      allow(mailer).to receive(:smtp_config_set_or_development?).and_return(true)

      mail = AdministratorNotifications::PlanUpgradeMailer.new_request(account, admin, start_plan, plus)

      expect(mail.to).to eq(['equipe@conexiia.test'])
      expect(mail.subject).to include("##{account.id}")
      expect(mail.body.encoded).to include('START', 'PLUS')
    end
  end
end
