require 'rails_helper'

RSpec.describe 'Super Admin: plano da conta', type: :request do
  let!(:super_admin) { create(:super_admin) }
  let(:account) { create(:account) }
  let(:plus) { Plan.create!(name: 'PLUS', slug: "plus-#{SecureRandom.hex(3)}", ai_credits_included: 1000) }
  let(:official_only) { Plan.create!(name: 'Só oficiais', slug: "oficial-#{SecureRandom.hex(3)}") }

  before do
    sign_in(super_admin, scope: :super_admin)
    plus.apply_feature_grid!(%w[whatsapp_channel whatsapp_unofficial_channel])
    official_only.apply_feature_grid!(%w[whatsapp_channel])
  end

  def save_account(plan_id)
    patch "/super_admin/accounts/#{account.id}", params: { account: { name: account.name }, account_plan_id: plan_id }
  end

  it 'mostra o seletor de plano na edição da conta' do
    get "/super_admin/accounts/#{account.id}/edit"

    expect(response).to have_http_status(:success)
    expect(response.body).to include('account_plan_id')
    expect(response.body).to include("PLUS (#{plus.slug})")
  end

  it 'escolher um plano cria a assinatura e aplica as features e créditos na conta' do
    save_account(plus.id)

    account.reload
    expect(account.subscriptions.current.first.plan).to eq(plus)
    expect(account.feature_enabled?('channel_whatsapp_unofficial')).to be(true)
    expect(account.ai_credit_balance.plan_credits).to eq(1000)
  end

  it 'trocar de plano cancela a assinatura anterior e aplica o novo' do
    save_account(plus.id)
    save_account(official_only.id)

    account.reload
    expect(account.subscriptions.current.first.plan).to eq(official_only)
    expect(account.subscriptions.where.not(status: :canceled).count).to eq(1)
    expect(account.feature_enabled?('channel_whatsapp_unofficial')).to be(false)
  end

  it 'salvar a conta com o mesmo plano não cria assinatura nova' do
    save_account(plus.id)

    expect { save_account(plus.id) }.not_to change(Subscription, :count)
  end

  it 'mostra o plano atual na página da conta' do
    save_account(plus.id)

    get "/super_admin/accounts/#{account.id}"

    expect(response.body).to include('PLUS')
  end

  it 'mostra o plano na listagem de contas, inclusive ordenando pela coluna' do
    save_account(plus.id)

    get '/super_admin/accounts', params: { account: { order: 'subscriptions', direction: 'desc' } }

    expect(response).to have_http_status(:success)
    expect(response.body).to include('PLUS')
  end
end
