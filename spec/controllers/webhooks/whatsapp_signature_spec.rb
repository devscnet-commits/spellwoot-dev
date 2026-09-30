require 'rails_helper'

# A Meta assina cada webhook do WhatsApp Cloud com o App Secret do app. Sem conferir, quem descobrisse a URL da
# caixa injetava mensagens falsas como se fossem de clientes.
RSpec.describe 'Webhooks do WhatsApp: assinatura da Meta', type: :request do
  let(:body) { { object: 'whatsapp_business_account', entry: [] }.to_json }

  def whatsapp_channel(provider_config)
    create(:channel_whatsapp, provider: 'whatsapp_cloud', phone_number: "+5549#{rand(10_000_000..99_999_999)}",
                              provider_config: { 'api_key' => 'k', 'phone_number_id' => '1', 'business_account_id' => '2' }.merge(provider_config),
                              sync_templates: false, validate_provider_config: false)
  end

  def post_webhook(channel, signature: nil)
    headers = { 'CONTENT_TYPE' => 'application/json' }
    headers['X-Hub-Signature-256'] = signature if signature
    post "/webhooks/whatsapp/#{channel.phone_number}", params: body, headers: headers
  end

  def sign(secret)
    "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', secret, body)}"
  end

  before { allow(Webhooks::WhatsappEventsJob).to receive(:perform_later) }

  context 'with caixa do cadastro Meta (app da plataforma)' do
    let(:channel) { whatsapp_channel('source' => 'embedded_signup') }

    before do
      allow(GlobalConfigService).to receive(:load).and_call_original
      allow(GlobalConfigService).to receive(:load).with('WHATSAPP_APP_SECRET', '').and_return('segredo-da-plataforma')
    end

    it 'aceita a assinatura feita com o App Secret da plataforma' do
      post_webhook(channel, signature: sign('segredo-da-plataforma'))

      expect(response).to have_http_status(:success)
      expect(Webhooks::WhatsappEventsJob).to have_received(:perform_later)
    end

    it 'recusa assinatura errada' do
      post_webhook(channel, signature: sign('outro-segredo'))

      expect(response).to have_http_status(:unauthorized)
      expect(Webhooks::WhatsappEventsJob).not_to have_received(:perform_later)
    end

    it 'recusa sem assinatura' do
      post_webhook(channel)

      expect(response).to have_http_status(:unauthorized)
      expect(Webhooks::WhatsappEventsJob).not_to have_received(:perform_later)
    end
  end

  context 'with caixa manual com App Secret próprio' do
    let(:channel) { whatsapp_channel('app_secret' => 'segredo-do-cliente') }

    it 'aceita a assinatura do app do cliente' do
      post_webhook(channel, signature: sign('segredo-do-cliente'))

      expect(response).to have_http_status(:success)
    end

    it 'recusa assinatura forjada' do
      post_webhook(channel, signature: sign('chute'))

      expect(response).to have_http_status(:unauthorized)
    end
  end

  context 'with caixa manual sem App Secret (como estava antes)' do
    let(:channel) { whatsapp_channel({}) }

    it 'continua aceitando, para não parar caixas existentes' do
      post_webhook(channel)

      expect(response).to have_http_status(:success)
      expect(Webhooks::WhatsappEventsJob).to have_received(:perform_later)
    end
  end
end
