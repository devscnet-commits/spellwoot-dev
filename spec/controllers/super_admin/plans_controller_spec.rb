require 'rails_helper'

RSpec.describe 'Super Admin plans', type: :request do
  let!(:super_admin) { create(:super_admin) }
  let!(:plan) { Plan.create!(name: 'PLUS', slug: "plus-#{SecureRandom.hex(3)}") }
  let(:account) { create(:account) }

  before { sign_in(super_admin, scope: :super_admin) }

  def save_plan(feature_keys, limits: {})
    patch "/super_admin/plans/#{plan.id}", params: {
      plan: { name: plan.name, slug: plan.slug },
      plan_grid_submitted: '1',
      plan_feature_keys: feature_keys,
      plan_limits: limits
    }
  end

  it 'mostra a tela de edição com os nomes em português e a escolha do WhatsApp' do
    get "/super_admin/plans/#{plan.id}/edit"

    expect(response).to have_http_status(:success)
    expect(response.body).to include('Somente oficiais (Meta Cloud API)')
    expect(response.body).to include('Caixas de entrada')
    expect(response.body).to include('Permitir e cobrar excedente')
  end

  it 'salvar "Somente oficiais" tira o WhatsApp não oficial das contas do plano' do
    plan.apply_feature_grid!(%w[whatsapp_channel whatsapp_unofficial_channel])
    Subscription.create!(account: account, plan: plan, status: :active, started_at: Time.current)
    expect(account.reload.feature_enabled?('channel_whatsapp_unofficial')).to be(true)

    # O rádio "Somente oficiais" envia valor vazio junto das caixas marcadas.
    save_plan(['whatsapp_channel', ''])

    expect(plan.reload.feature_enabled?('whatsapp_unofficial_channel')).to be(false)
    account.reload
    expect(account.feature_enabled?('channel_whatsapp')).to be(true)
    expect(account.feature_enabled?('channel_whatsapp_unofficial')).to be(false)
  end

  it 'salvar "Todas" libera o WhatsApp não oficial nas contas do plano' do
    Subscription.create!(account: account, plan: plan, status: :active, started_at: Time.current)

    save_plan(%w[whatsapp_channel whatsapp_unofficial_channel])

    expect(account.reload.feature_enabled?('channel_whatsapp_unofficial')).to be(true)
  end

  it 'grava os limites da tela' do
    save_plan(%w[whatsapp_channel], limits: { users: { max_value: '3', overflow_behavior: 'hard_block' },
                                              inboxes: { max_value: '', overflow_behavior: 'paid_overage' } })

    expect(plan.reload.limit_for('users').max_value).to eq(3)
    expect(plan.limit_for('inboxes').max_value).to be_nil
    expect(plan.limit_for('inboxes').overflow_behavior).to eq('paid_overage')
  end
end
