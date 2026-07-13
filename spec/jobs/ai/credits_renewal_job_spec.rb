require 'rails_helper'

RSpec.describe Ai::CreditsRenewalJob do
  let(:account) { create(:account) }
  let(:plan) { Plan.create!(name: 'Básico', slug: "basico-#{SecureRandom.hex(4)}", ai_credits_included: 100) }
  let!(:subscription) do
    sub = Subscription.create!(account: account, plan: plan, status: :active, started_at: 2.months.ago)
    sub.update!(next_renewal_at: 1.day.ago) # ciclo vencido -> renova
    sub
  end

  it 'reseta plan_credits para o teto E o flag low_balance_notified_at na renovação' do
    # A subscription já criou o balance (plan_credits=100). Simula fim de ciclo com saldo baixo + já avisado.
    balance = account.ai_credit_balance
    balance.update!(plan_credits: 3, extra_credits: 7, low_balance_notified_at: Time.current)

    described_class.new.perform

    balance.reload
    expect(balance.plan_credits).to eq(100)             # resetado pro teto do plano
    expect(balance.low_balance_notified_at).to be_nil   # flag de aviso resetada (pode avisar de novo)
    expect(balance.extra_credits).to eq(7)              # avulsos NÃO são tocados na renovação
  end
end
