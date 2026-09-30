require 'rails_helper'

# Caminhos de criação que o mapa de travas marcou "sem teste automático": Super Admin, seed, SSO, cadastro,
# OAuth de e-mail, cadastro do WhatsApp oficial, Telegram, SMS, WhatsApp Cloud/360Dialog, Facebook, Instagram,
# Line/TikTok/Twitter/Voz, migração de e-mail da Platform API, e os módulos de trava antiga (SLA, auditoria,
# chave própria de IA). Cada um prova que o caminho real passa pela trava do plano (PlanLimited/PlanChannelGated
# no modelo, ou o gate do controller) e que nada fica criado pela metade.
RSpec.describe 'Travas do plano nos demais caminhos de criação', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:headers) { admin.create_new_auth_token }

  def fill_plan(key, max)
    subscribe_account_to_plan(account, features: Plan::MANAGED_FEATURE_KEYS, limits: { key => max })
    account.reload
    RequestStore.clear!
  end

  def plan_without(*plan_keys)
    subscribe_account_to_plan(account, features: Plan::MANAGED_FEATURE_KEYS - plan_keys.map(&:to_s))
    account.reload
    RequestStore.clear!
  end

  # Conta com 1 caixa e plano de 1 caixa: a próxima tem que ser recusada.
  def fill_inboxes!
    create(:inbox, account: account)
    fill_plan('inboxes', 1)
  end

  # WhatsApp oficial valida credenciais e sincroniza templates na Meta/360Dialog ao criar o canal.
  def stub_whatsapp_provider_calls
    allow_any_instance_of(Channel::Whatsapp).to receive(:validate_provider_config) # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(Channel::Whatsapp).to receive(:sync_templates) # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(Channel::Whatsapp).to receive(:setup_webhooks) # rubocop:disable RSpec/AnyInstance
  end

  describe 'usuários' do
    before { admin }

    it 'Super Admin → Adicionar usuário à conta: recusa com aviso, sem criar o vínculo' do
      fill_plan('users', 1)
      other = create(:user)
      sign_in(create(:super_admin), scope: :super_admin)

      expect do
        post '/super_admin/account_users', params: { account_user: { account_id: account.id, user_id: other.id, role: 'agent' } }
      end.not_to change(AccountUser, :count)
      expect(response).to have_http_status(:redirect)
      expect(flash[:error]).to match(/Limite de .* do seu plano atingido/)
    end

    it 'Super Admin → Semear dados: para no limite de usuários' do
      fill_plan('users', 1)

      expect { Seeders::AccountSeeder.new(account: account).perform! }.to raise_error(CustomExceptions::Plan::LimitExceeded)
      expect(account.account_users.count).to eq(1)
    end

    it 'primeiro login por SSO/SAML: recusa o vínculo com a conta cheia sem deixar usuário solto' do
      fill_plan('users', 1)
      auth_hash = { 'provider' => 'saml', 'uid' => 'saml-1', 'info' => { 'email' => 'sso@example.com', 'name' => 'SSO' } }

      expect { SamlUserBuilder.new(auth_hash, account.id).perform }.to raise_error(CustomExceptions::Plan::LimitExceeded)
      expect(account.account_users.count).to eq(1)
      expect(User.from_email('sso@example.com')).to be_nil
    end

    it 'cadastro de conta nova: o dono sempre entra (a conta nasce sem plano)' do
      user, new_account = AccountBuilder.new(account_name: 'Nova', email: 'dono@example.com', user_password: 'Password1!.',
                                             confirmed: true).perform

      expect(new_account.account_users.where(user: user, role: :administrator)).to exist
    end
  end

  describe 'caixas — OAuth de e-mail (Google / Microsoft)' do
    let(:email) { 'caixa@example.com' }
    let(:state) { account.to_sgid(expires_in: 15.minutes).to_s }
    let(:token_body) do
      { id_token: JWT.encode({ email: email, name: 'Caixa' }, false), access_token: 'at', token_type: 'Bearer', refresh_token: 'rt' }
    end

    {
      'Google' => ['https://accounts.google.com/o/oauth2/token', :google_callback_url],
      'Microsoft' => ['https://login.microsoftonline.com/common/oauth2/v2.0/token', :microsoft_callback_url]
    }.each do |provider, (token_url, callback)|
      it "#{provider}: com o limite cheio não cria caixa e volta para a tela de e-mail com o aviso" do
        fill_inboxes!
        stub_request(:post, token_url).to_return(status: 200, body: token_body.to_json, headers: { 'Content-Type' => 'application/json' })

        expect do
          get send(callback), params: { code: 'c', state: state }
        end.not_to change(Channel::Email, :count)
        expect(account.inboxes.count).to eq(1)
        expect(response).to redirect_to(
          app_new_email_inbox_url(account_id: account.id, error_message: 'Limite de caixas de entrada do seu plano atingido.')
        )
      end

      it "#{provider}: com E-mail fora do plano não cria caixa" do
        plan_without('email_channel')
        stub_request(:post, token_url).to_return(status: 200, body: token_body.to_json, headers: { 'Content-Type' => 'application/json' })

        expect do
          get send(callback), params: { code: 'c', state: state }
        end.not_to change(Inbox, :count)
        expect(response.location).to include('/settings/inboxes/new/email?error_message=')
      end
    end
  end

  describe 'caixas — POST /inboxes por canal' do
    let(:url) { "/api/v1/accounts/#{account.id}/inboxes" }

    before do
      stub_request(:any, /api.telegram.org/).to_return(status: 200, body: { ok: true, result: {} }.to_json,
                                                       headers: { 'Content-Type' => 'application/json' })
      stub_whatsapp_provider_calls
    end

    {
      'Telegram' => ['telegram_channel', { type: 'telegram', bot_token: '123:abc' }],
      'SMS Bandwidth' => ['sms_channel', { type: 'sms', phone_number: '+5549999990001',
                                           provider_config: { account_id: '1', application_id: '1', api_key: '1', api_secret: '1' } }],
      'WhatsApp Cloud (manual)' => ['whatsapp_channel', { type: 'whatsapp', phone_number: '+5549999990002', provider: 'whatsapp_cloud',
                                                          provider_config: { api_key: 'k', phone_number_id: '1', business_account_id: '2' } }],
      'WhatsApp 360Dialog' => ['whatsapp_channel', { type: 'whatsapp', phone_number: '+5549999990003', provider: 'default',
                                                     provider_config: { api_key: 'k' } }]
    }.each do |label, (plan_key, channel)|
      it "#{label}: fora do plano não cria" do
        plan_without(plan_key)

        expect do
          post url, headers: headers, params: { name: label, channel: channel }, as: :json
        end.not_to change(Inbox, :count)
        expect(response).not_to have_http_status(:success)
      end

      it "#{label}: com o limite cheio recusa (402) sem deixar canal solto" do
        fill_inboxes!

        expect do
          post url, headers: headers, params: { name: label, channel: channel }, as: :json
        end.not_to change(Inbox, :count)
        expect(response).to have_http_status(:payment_required)
      end

      it "#{label}: no plano e com vaga, cria" do
        fill_plan('inboxes', 5)

        expect do
          post url, headers: headers, params: { name: label, channel: channel }, as: :json
        end.to change(Inbox, :count).by(1)
      end
    end
  end

  describe 'caixas — cadastro do WhatsApp oficial (embedded signup)' do
    let(:service) do
      Whatsapp::ChannelCreationService.new(account, { waba_id: 'w', business_name: 'Loja' },
                                           { phone_number: '+5549999990010', phone_number_id: 'p' }, 'token')
    end

    before { stub_whatsapp_provider_calls }

    it 'WhatsApp fora do plano: recusa e não deixa canal solto' do
      plan_without('whatsapp_channel')

      expect { service.perform }.to raise_error(CustomExceptions::Plan::FeatureUnavailable)
      expect(Channel::Whatsapp.where(account_id: account.id)).to be_empty
    end

    it 'limite cheio: recusa e não deixa canal solto' do
      fill_inboxes!

      expect { service.perform }.to raise_error(CustomExceptions::Plan::LimitExceeded)
      expect(Channel::Whatsapp.where(account_id: account.id)).to be_empty
    end
  end

  describe 'caixas — Facebook (register_facebook_page)' do
    let(:url) { "/api/v1/accounts/#{account.id}/callbacks/register_facebook_page" }
    let(:params) { { page_id: 'pg-1', user_access_token: 'u', page_access_token: 'p', inbox_name: 'Página' } }
    let(:koala_api) { instance_double(Koala::Facebook::API) }

    before do
      stub_request(:any, /graph.facebook.com/)
      allow(Koala::Facebook::API).to receive(:new).and_return(koala_api)
      allow(koala_api).to receive(:get_connections).and_return({})
      allow(Facebook::Messenger::Subscriptions).to receive(:subscribe).and_return(true)
    end

    it 'Facebook fora do plano: 403 e nada criado' do
      plan_without('facebook_channel')

      expect { post url, headers: headers, params: params, as: :json }.not_to change(Channel::FacebookPage, :count)
      expect(response).to have_http_status(:forbidden)
    end

    it 'limite cheio: 402 com o aviso, sem criar caixa nem página' do
      fill_inboxes!

      expect { post url, headers: headers, params: params, as: :json }.not_to change(Channel::FacebookPage, :count)
      expect(account.inboxes.count).to eq(1)
      expect(response).to have_http_status(:payment_required)
      expect(response.parsed_body['error']).to eq('Limite de caixas de entrada do seu plano atingido.')
    end
  end

  describe 'caixas — canais fora da grade do plano (Line, TikTok, Twitter/X, Voz)' do
    {
      'Line' => -> { Channel::Line.create!(account: account, line_channel_id: SecureRandom.hex, line_channel_secret: 's', line_channel_token: 't') },
      'TikTok' => lambda {
        Channel::Tiktok.create!(account: account, business_id: SecureRandom.hex, access_token: 'a', refresh_token: 'r',
                                expires_at: 1.day.from_now, refresh_token_expires_at: 30.days.from_now)
      },
      'Twitter/X' => -> { Channel::TwitterProfile.create!(account: account, profile_id: SecureRandom.hex, twitter_access_token: 'a', twitter_access_token_secret: 's') },
      'Voz' => lambda {
        channel = Channel::Voice.new(account: account, phone_number: "+55499#{rand(10_000_000..99_999_999)}", provider: 'twilio',
                                     provider_config: { account_sid: 'AC1', auth_token: 't', api_key_sid: 'k', api_key_secret: 's', twiml_app_sid: 'AP1' })
        channel.define_singleton_method(:provision_twilio_on_create) { nil }
        channel.define_singleton_method(:validate_provider_config) { nil }
        channel.save!
        channel
      }
    }.each do |label, build_channel|
      it "#{label}: sem módulo no plano (qualquer plano cria), mas respeita o limite de caixas" do
        subscribe_account_to_plan(account, features: [], limits: { 'inboxes' => 1 })
        account.reload
        RequestStore.clear!

        expect(Inbox.create!(account: account, name: label, channel: instance_exec(&build_channel))).to be_persisted
        expect { Inbox.create!(account: account, name: "#{label} 2", channel: instance_exec(&build_channel)) }
          .to raise_error(CustomExceptions::Plan::LimitExceeded)
      end
    end
  end

  describe 'caixas — migração de e-mail (Platform API)' do
    let(:platform_app) { create(:platform_app) }
    let(:params) do
      { migrations: [{ email: 'migra@example.com', provider: 'google', inbox_name: 'Migrada',
                       provider_config: { access_token: 'a', refresh_token: 'r', expires_on: 1.hour.from_now.to_s } }] }
    end

    before { create(:platform_app_permissible, platform_app: platform_app, permissible: account) }

    it 'limite cheio: a entrada volta com erro de limite e nada é criado' do
      fill_inboxes!

      with_modified_env EMAIL_CHANNEL_MIGRATION: 'true' do
        expect do
          post "/platform/api/v1/accounts/#{account.id}/email_channel_migrations",
               params: params, headers: { api_access_token: platform_app.access_token.token }, as: :json
        end.not_to change(Channel::Email, :count)
      end
      result = response.parsed_body['results'].first
      expect(result['status']).to eq('error')
      expect(result['message']).to match(/Limite de .* do seu plano atingido/)
    end
  end

  describe 'caixas — Super Admin → Semear dados' do
    it 'para no limite de caixas' do
      fill_inboxes!

      expect { Seeders::InboxSeeder.new(account: account, company_data: { 'name' => 'Loja', 'domain' => 'loja.test' }).perform! }
        .to raise_error(CustomExceptions::Plan::LimitExceeded)
      expect(account.inboxes.count).to eq(1)
    end
  end

  describe 'módulos de trava antiga' do
    it 'SLA fora do plano: 403 ao criar' do
      plan_without('sla_tracking')

      expect do
        post "/api/v1/accounts/#{account.id}/sla_policies", headers: headers,
                                                            params: { name: 'SLA', first_response_time_threshold: 60 }, as: :json
      end.not_to change(SlaPolicy, :count)
      expect(response).to have_http_status(:forbidden)
    end

    it 'Logs de auditoria fora do plano: a lista volta vazia' do
      plan_without('audit_logs')
      admin.update!(name: 'Outro nome')

      get "/api/v1/accounts/#{account.id}/audit_logs", headers: headers, as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['audit_logs']).to be_empty
    end

    it 'Chave própria de IA fora do plano: a chave salva não é usada' do
      IntegrationSetting.create!(account_id: account.id, provider: 'openai', enabled: true, config: { apiKey: 'sk-da-conta' }.to_json)

      plan_without('custom_llm_api_key')
      expect(Ai::ModelRouter.account_provider_key(account.id, 'openai')).to be_nil

      byok_account = create(:account)
      enable_byok!(byok_account)
      IntegrationSetting.create!(account_id: byok_account.id, provider: 'openai', enabled: true, config: { apiKey: 'sk-outra' }.to_json)
      RequestStore.clear!
      expect(Ai::ModelRouter.account_provider_key(byok_account.id, 'openai')).to eq('sk-outra')
    end
  end
end
