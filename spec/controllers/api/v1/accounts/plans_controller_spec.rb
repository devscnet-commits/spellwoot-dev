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
  let(:agent) { create(:user, account: account, role: :agent) }

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

  describe 'POST /api/v1/accounts/{account.id}/plan/upgrade' do
    let(:start_plan) { subscribe_account_to_plan(account) }
    let(:plus) { Plan.create!(name: 'PLUS', slug: "plus-#{SecureRandom.hex(3)}") }

    before do
      start_plan.update!(slug: 'start')
      plus.update!(slug: 'plus')
    end

    it 'admin consegue fazer upgrade self-service' do
      post "/api/v1/accounts/#{account.id}/plan/upgrade",
           params: { plan_slug: plus.slug }, headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:ok)
      expect(account.reload.subscriptions.current.first.plan).to eq(plus)
    end

    it 'agente não pode trocar de plano' do
      post "/api/v1/accounts/#{account.id}/plan/upgrade",
           params: { plan_slug: plus.slug }, headers: agent.create_new_auth_token, as: :json

      expect(response).to have_http_status(:forbidden)
    end

    it 'recusa downgrade' do
      account.subscriptions.current.first.update!(plan: plus)

      post "/api/v1/accounts/#{account.id}/plan/upgrade",
           params: { plan_slug: start_plan.slug }, headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end
end
