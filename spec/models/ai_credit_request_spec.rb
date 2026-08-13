require 'rails_helper'

RSpec.describe AiCreditRequest do
  let(:account) { create(:account) }
  let(:user) { create(:user, account: account) }
  let(:admin) { create(:user, account: account, role: :administrator) }

  def build_request(attrs = {})
    account.ai_credit_requests.new({ requested_by: user, amount_requested: 500, reason: 'preciso' }.merge(attrs))
  end

  describe 'validations' do
    it 'é válido com amount > 0' do
      expect(build_request).to be_valid
    end

    it 'rejeita amount <= 0' do
      expect(build_request(amount_requested: 0)).not_to be_valid
    end

    it 'permite só UMA solicitação pendente por conta' do
      build_request.save!
      expect(build_request).not_to be_valid
    end

    it 'libera nova solicitação quando a anterior deixou de estar pendente' do
      first = build_request
      first.save!
      first.update!(status: :rejected)

      expect(build_request).to be_valid
    end
  end

  describe '#approve!' do
    it 'credita amount_requested nos extra_credits e marca approved' do
      request = build_request(amount_requested: 300)
      request.save!

      expect { request.approve!(by: admin) }
        .to change { account.reload.ai_credit_balance&.extra_credits || 0 }.by(300)
      expect(request.reload).to be_approved
      expect(request.approved_by).to eq(admin)
      expect(request.reviewed_at).to be_present
    end

    it 'é idempotente: aprovar de novo levanta InvalidTransition e NÃO credita 2x' do
      request = build_request(amount_requested: 300)
      request.save!
      request.approve!(by: admin)

      expect { request.approve!(by: admin) }.to raise_error(AiCreditRequest::InvalidTransition)
      expect(account.reload.ai_credit_balance.extra_credits).to eq(300)
    end
  end

  describe '#reject!' do
    it 'marca rejected com a nota e NÃO credita' do
      request = build_request
      request.save!

      expect { request.reject!(by: admin, note: 'sem saldo') }
        .not_to(change { account.reload.ai_credit_balance&.extra_credits })
      expect(request.reload).to be_rejected
      expect(request.review_note).to eq('sem saldo')
    end
  end
end
