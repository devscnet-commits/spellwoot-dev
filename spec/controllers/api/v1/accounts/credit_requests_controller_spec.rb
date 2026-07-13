require 'rails_helper'

RSpec.describe 'Credit Requests API', type: :request do
  include ActiveJob::TestHelper

  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }

  describe 'POST /api/v1/accounts/:account_id/credit_requests' do
    it 'cria a solicitação pending e enfileira o mailer de notificação' do
      expect do
        post "/api/v1/accounts/#{account.id}/credit_requests",
             params: { credit_request: { amount_requested: 1000, reason: 'preciso' } },
             headers: admin.create_new_auth_token, as: :json
      end.to change(AiCreditRequest, :count).by(1)
        .and(have_enqueued_mail(AdministratorNotifications::CreditRequestMailer, :new_request))

      expect(response).to have_http_status(:created)
      request = AiCreditRequest.last
      expect(request).to be_pending
      expect(request.requested_by).to eq(admin)
      expect(request.amount_requested).to eq(1000)
    end

    it 'rejeita amount <= 0 com 422' do
      post "/api/v1/accounts/#{account.id}/credit_requests",
           params: { credit_request: { amount_requested: 0 } },
           headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe 'GET /api/v1/accounts/:account_id/credit_requests' do
    it 'lista as solicitações da conta' do
      account.ai_credit_requests.create!(requested_by: admin, amount_requested: 500)

      get "/api/v1/accounts/#{account.id}/credit_requests", headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body.size).to eq(1)
      expect(response.parsed_body.first['status']).to eq('pending')
    end
  end
end
