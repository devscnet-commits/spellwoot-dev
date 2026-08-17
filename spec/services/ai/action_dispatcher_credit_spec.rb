require 'rails_helper'

# Consumo de crédito de IA no reply.sent (billing Fase 2). Isola o deliver (não cria mensagem real)
# e força o ReplyPolicy pra :live — o foco é o débito de crédito, não a entrega.
RSpec.describe Ai::ActionDispatcher do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:profile) do
    Ai::OperationProfile.create!(account_id: account.id, name: 'balanceado',
                                 supervisor_provider: 'openai', supervisor_model: 'gpt-4.1-mini')
  end
  let(:agent) { Ai::Agent.create!(account: account, name: 'Bot', status: 'active', ai_operation_profile_id: profile.id) }
  let(:department) do
    Ai::Department.create!(account: account, ai_agent_id: agent.id, name: 'Atendimento', status: 'active', behavior: {})
  end
  let(:dispatcher) do
    described_class.new(conversation: conversation, account: account, mode: 'live', acts_live: true)
  end

  before do
    allow(Ai::ReplyPolicy).to receive(:effective_reply_state).and_return(:live)
    allow(Ai::ReplyPolicy).to receive(:skip_reason).and_return('shadow_mode')
    allow(dispatcher).to receive(:deliver) # não cria mensagem real — foco no crédito
  end

  it 'consome 1 crédito por resposta enviada (reply.sent)' do
    balance = account.create_ai_credit_balance!(plan_credits: 5, extra_credits: 0)

    expect { dispatcher.reply(department, 'olá') }.to change { balance.reload.total }.by(-1)
    expect(Ai::Event.where(conversation_id: conversation.id, event_type: 'reply.sent')).to exist
  end

  it 'debita primeiro do plan_credits (extra_credits intacto)' do
    balance = account.create_ai_credit_balance!(plan_credits: 2, extra_credits: 3)
    dispatcher.reply(department, 'olá')

    expect(balance.reload.plan_credits).to eq(1)
    expect(balance.extra_credits).to eq(3)
  end

  it 'é nil-safe: conta SEM balance não quebra e ainda envia (fail-open)' do
    expect { dispatcher.reply(department, 'olá') }.not_to raise_error
    expect(Ai::Event.where(conversation_id: conversation.id, event_type: 'reply.sent')).to exist
  end

  it 'best-effort: saldo já zerado não trava a resposta (rescue InsufficientCredits)' do
    account.create_ai_credit_balance!(plan_credits: 0, extra_credits: 0)

    expect { dispatcher.reply(department, 'olá') }.not_to raise_error
    expect(Ai::Event.where(conversation_id: conversation.id, event_type: 'reply.sent')).to exist
  end

  it 'NÃO consome quando não entrega (shadow: reply.intended, sem reply.sent)' do
    allow(Ai::ReplyPolicy).to receive(:effective_reply_state).and_return(:shadow)
    balance = account.create_ai_credit_balance!(plan_credits: 5)

    expect { dispatcher.reply(department, 'olá') }.not_to(change { balance.reload.total })
    expect(Ai::Event.where(conversation_id: conversation.id, event_type: 'reply.sent')).not_to exist
  end
end
