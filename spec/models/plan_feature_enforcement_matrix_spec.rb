require 'rails_helper'

# Matriz de travas de MÓDULO do plano: para cada módulo que o servidor trava, uma conta com plano SEM ele
# (fluxo real: assinatura -> Plan#sync_features_to! -> bitmask da conta) tenta usar pelo caminho que importa,
# e uma conta com o módulo consegue. Canais são travados na criação da caixa (PlanChannelGated) — cobre
# qualquer caminho: tela, API, cadastro do WhatsApp oficial, OAuth de e-mail, Platform API, console.
RSpec.describe 'Travas de módulo do plano', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:headers) { admin.create_new_auth_token }

  def plan_without(*plan_keys)
    subscribe_account_to_plan(account, features: Plan::MANAGED_FEATURE_KEYS - plan_keys.map(&:to_s))
    account.reload
    RequestStore.clear!
  end

  def plan_with_everything
    plan_without
  end

  def new_inbox(channel)
    Inbox.create!(account: account, name: 'Caixa', channel: channel)
  end

  describe 'canais — criação da caixa' do
    {
      'webchat_channel' => -> { Channel::WebWidget.create!(account: account, website_url: 'https://x.test') },
      'api_channel' => -> { Channel::Api.create!(account: account) },
      'email_channel' => -> { Channel::Email.create!(account: account, email: "c#{SecureRandom.hex(3)}@x.test", forward_to_email: "f#{SecureRandom.hex(3)}@x.test") },
      'sms_channel' => -> { Channel::TwilioSms.create!(account: account, medium: :sms, auth_token: 't', account_sid: 's', messaging_service_sid: "MG#{SecureRandom.hex(16)}") },
      'whatsapp_channel' => -> { Channel::TwilioSms.create!(account: account, medium: :whatsapp, auth_token: 't', account_sid: 's', messaging_service_sid: "MG#{SecureRandom.hex(16)}") }
    }.each do |plan_key, build_channel|
      it "#{plan_key} fora do plano: bloqueia; no plano: cria" do
        plan_without(plan_key)
        expect { new_inbox(instance_exec(&build_channel)) }.to raise_error(CustomExceptions::Plan::FeatureUnavailable)

        plan_with_everything
        expect(new_inbox(instance_exec(&build_channel))).to be_persisted
      end
    end

    it 'WhatsApp não oficial (UazAPI) fora do plano: bloqueia mesmo com Canal API liberado' do
      plan_without('whatsapp_unofficial_channel')
      uazapi = Channel::Api.create!(account: account, additional_attributes: { 'uazapi_instance_token' => 'tok' })

      expect { new_inbox(uazapi) }.to raise_error(CustomExceptions::Plan::FeatureUnavailable, /apenas integrações oficiais/)
    end

    it 'UazAPI não depende do Canal API: plano só com WhatsApp (+ não oficial) cria' do
      plan_without('api_channel')
      uazapi = Channel::Api.create!(account: account, additional_attributes: { 'uazapi_instance_token' => 'tok' })

      expect(new_inbox(uazapi)).to be_persisted
    end

    it 'POST /inboxes com canal fora do plano: não cria' do
      plan_without('api_channel')

      expect do
        post "/api/v1/accounts/#{account.id}/inboxes", headers: headers, params: { name: 'X', channel: { type: 'api' } }, as: :json
      end.not_to change(Inbox, :count)

      expect(response.status).to be_in([403, 422])
    end

    it 'caixa interna de teste da IA não é barrada pelo plano' do
      plan_without('api_channel')

      expect(account.inboxes.create!(name: Inbox::AI_TEST_INBOX_NAME, channel: Channel::Api.create!(account: account))).to be_persisted
    end

    it 'conta sem plano segue o padrão (canais liberados) — contas internas não são barradas' do
      expect(new_inbox(Channel::Api.create!(account: account))).to be_persisted
    end
  end

  describe 'Relatórios / Dashboards BI (dashboards_bi)' do
    %w[/api/v2/accounts/%<id>s/reports/conversations /api/v2/accounts/%<id>s/live_reports/conversation_metrics].each do |path|
      it "#{path.split('/').last(2).join('/')}: 403 sem o módulo, 200 com" do
        url = format(path, id: account.id)
        plan_without('dashboards_bi')
        get url, headers: headers, params: { type: :account }, as: :json
        expect(response).to have_http_status(:forbidden)

        plan_with_everything
        get url, headers: headers, params: { type: :account }, as: :json
        expect(response).to have_http_status(:ok)
      end
    end
  end

  describe 'Copiloto de IA (ai_copilot)' do
    it '403 sem o módulo' do
      plan_without('ai_copilot')
      conversation = create(:conversation, account: account)

      post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/ai_copilot", headers: headers, as: :json

      expect(response).to have_http_status(:forbidden)
    end
  end

  describe 'API de Conversões Meta (conversion_api)' do
    it 'sem o módulo nada é enviado à Meta, mesmo com o interruptor da conta ligado' do
      plan_without('conversion_api')
      conversation = create(:conversation, account: account)
      service = Meta::ConversionsApiService.new(conversation: conversation)

      expect(service.send(:skip_reason)).to eq('plan_without_conversion_api')
      expect(service.send(:trackable?)).to be(false)
    end
  end

  describe 'Webhooks (webhook_api)' do
    it '403 ao criar webhook sem o módulo' do
      plan_without('webhook_api')

      post "/api/v1/accounts/#{account.id}/webhooks", headers: headers,
                                                       params: { webhook: { url: 'https://hook.test', subscriptions: ['message_created'] } }, as: :json

      expect(response).to have_http_status(:forbidden)
    end
  end
end
