require 'rails_helper'

RSpec.describe 'Super Admin credit requests', type: :request do
  let!(:super_admin) { create(:super_admin) }
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let!(:credit_request) do
    account.ai_credit_requests.create!(requested_by: user, amount_requested: 400, reason: 'preciso')
  end

  describe 'POST /super_admin/credit_requests/:id/approve' do
    context 'quando autenticado como super admin' do
      before { sign_in(super_admin, scope: :super_admin) }

      it 'credita os extra_credits da conta e marca a solicitação como aprovada' do
        expect { post "/super_admin/credit_requests/#{credit_request.id}/approve" }
          .to change { account.reload.ai_credit_balance&.extra_credits || 0 }.by(400)

        expect(credit_request.reload).to be_approved
        expect(response).to have_http_status(:redirect)
      end
    end

    context 'quando não autenticado' do
      it 'redireciona (não autorizado)' do
        post "/super_admin/credit_requests/#{credit_request.id}/approve"
        expect(response).to have_http_status(:redirect)
        expect(credit_request.reload).to be_pending
      end
    end
  end

  describe 'POST /super_admin/credit_requests/:id/reject' do
    before { sign_in(super_admin, scope: :super_admin) }

    it 'marca rejected com a nota e NÃO credita' do
      post "/super_admin/credit_requests/#{credit_request.id}/reject", params: { review_note: 'sem saldo' }

      expect(credit_request.reload).to be_rejected
      expect(credit_request.review_note).to eq('sem saldo')
      expect(account.reload.ai_credit_balance).to be_nil
    end
  end
end
