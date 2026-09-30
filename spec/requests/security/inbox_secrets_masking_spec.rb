require 'rails_helper'

# Segredos dos canais não saem inteiros na lista de caixas (aparece no "Inspecionar" de todo navegador logado).
# Vão mascarados; o valor completo só pelo endpoint de revelar (admin); salvar a tela sem mexer no campo
# mascarado não troca o segredo pelo texto com asteriscos.
RSpec.describe 'Segredos das caixas mascarados', type: :request do
  let(:account) { create(:account) }
  let!(:whatsapp_inbox) { create(:inbox, account: account, channel: whatsapp_channel) }
  let(:email_channel) do
    create(:channel_email, account: account, imap_enabled: true, imap_password: 'senha-imap-super-secreta',
                           smtp_enabled: true, smtp_password: 'senha-smtp-super-secreta')
  end
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }

  let(:api_channel) { Channel::Api.create!(account: account, secret: 'segredo-do-webhook-123456') }
  let!(:api_inbox) { Inbox.create!(account: account, name: 'API', channel: api_channel) }
  let(:whatsapp_channel) do
    channel = create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false)
    # rubocop:disable Rails/SkipsModelValidations
    channel.update_columns(provider_config: { 'api_key' => 'EAAG-chave-meta-completa-xyz', 'phone_number_id' => '111',
                                              'business_account_id' => '222', 'webhook_verify_token' => 'verifica-meta-abcdef',
                                              'app_secret' => 'app-secret-do-cliente-999' })
    # rubocop:enable Rails/SkipsModelValidations
    channel
  end

  before do
    # Salvar o canal do WhatsApp valida a chave e sincroniza templates na Meta.
    allow_any_instance_of(Channel::Whatsapp).to receive(:validate_provider_config) # rubocop:disable RSpec/AnyInstance
    allow_any_instance_of(Channel::Whatsapp).to receive(:sync_templates) # rubocop:disable RSpec/AnyInstance
  end

  def inboxes_body(user)
    get "/api/v1/accounts/#{account.id}/inboxes", headers: user.create_new_auth_token, as: :json
    response.body
  end

  it 'a lista de caixas não traz nenhum segredo inteiro (nem para admin)' do
    email_channel
    body = inboxes_body(admin)

    [api_channel.hmac_token, api_channel.identifier, 'segredo-do-webhook-123456', 'EAAG-chave-meta-completa-xyz',
     'verifica-meta-abcdef', 'app-secret-do-cliente-999', 'senha-imap-super-secreta', 'senha-smtp-super-secreta'].each do |secret|
      expect(body).not_to include(secret)
    end
    expect(body).to include(SecretMaskingHelper.mask_secret('EAAG-chave-meta-completa-xyz'))
  end

  it 'campos que não são segredo seguem inteiros' do
    inbox = JSON.parse(inboxes_body(admin))['payload'].find { |i| i['id'] == whatsapp_inbox.id }

    expect(inbox['provider_config']).to include('phone_number_id' => '111', 'business_account_id' => '222')
  end

  describe 'GET /inboxes/:id/secret' do
    def reveal(user, inbox, field)
      get "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}/secret", headers: user.create_new_auth_token,
                                                                       params: { field: field }, as: :json
    end

    it 'admin recebe o valor completo de um campo' do
      reveal(admin, whatsapp_inbox, 'webhook_verify_token')
      expect(response.parsed_body['value']).to eq('verifica-meta-abcdef')

      reveal(admin, api_inbox, 'inbox_identifier')
      expect(response.parsed_body['value']).to eq(api_channel.identifier)
    end

    it 'agente não recebe (nem da caixa da qual é membro)' do
      create(:inbox_member, user: agent, inbox: api_inbox)
      reveal(agent, api_inbox, 'hmac_token')

      expect(response).to have_http_status(:unauthorized)
      expect(response.body).not_to include(api_channel.hmac_token)
    end

    it 'campo fora da lista não devolve nada' do
      reveal(admin, api_inbox, 'website_url')

      expect(response).to have_http_status(:not_found)
    end

    it 'admin não revela segredo de caixa de outra conta' do
      other_inbox = create(:inbox, account: create(:account))
      reveal(admin, other_inbox, 'hmac_token')

      expect(response).to have_http_status(:not_found)
    end
  end

  describe 'salvar a tela com o valor mascarado' do
    it 'mantém o segredo real (WhatsApp: tela manda o provider_config que recebeu + App Secret novo)' do
      masked = Inboxes::SecretFields.masked_provider_config(whatsapp_channel.provider_config)

      patch "/api/v1/accounts/#{account.id}/inboxes/#{whatsapp_inbox.id}", headers: admin.create_new_auth_token,
                                                                             params: { channel: { provider_config: masked.merge('app_secret' => 'app-secret-novo') } },
                                                                             as: :json

      expect(response).to have_http_status(:success)
      expect(whatsapp_channel.reload.provider_config).to include('api_key' => 'EAAG-chave-meta-completa-xyz',
                                                                 'webhook_verify_token' => 'verifica-meta-abcdef',
                                                                 'app_secret' => 'app-secret-novo')
    end

    it 'mantém a senha do e-mail quando a tela devolve a senha mascarada' do
      email_inbox = email_channel.inbox

      patch "/api/v1/accounts/#{account.id}/inboxes/#{email_inbox.id}", headers: admin.create_new_auth_token,
                                                                          params: { channel: { smtp_password: SecretMaskingHelper.mask_secret('senha-smtp-super-secreta') } },
                                                                          as: :json

      expect(email_channel.reload.smtp_password).to eq('senha-smtp-super-secreta')
    end
  end
end
