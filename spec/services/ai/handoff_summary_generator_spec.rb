require 'rails_helper'

RSpec.describe Ai::HandoffSummaryGenerator do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:profile) do
    Ai::OperationProfile.create!(account_id: account.id, name: 'balanceado',
                                 supervisor_provider: 'openai', supervisor_model: 'gpt-4.1-mini')
  end
  let(:agent) { Ai::Agent.create!(account: account, name: 'Bot', status: 'active', ai_operation_profile_id: profile.id) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }

  before do
    Ai::AgentInbox.create!(ai_agent_id: agent.id, inbox_id: inbox.id, mode: 'live', active: true)
    create(:message, account: account, inbox: inbox, conversation: conversation,
                     message_type: 'incoming', content: 'quero cancelar meu plano agora')
    allow(Ai::ModelRouter).to receive(:decide).and_return(
      { provider: 'openai', model: 'gpt-4.1-mini', decision: { 'summary' => 'Cliente quer cancelar o plano.' },
        tokens_in: 10, tokens_out: 5, cost: 0.001, latency_ms: 20, status: 'recorded' }
    )
  end

  it 'gera o resumo e cria Ai::HandoffSummary + Ai::Run, SEM consumir crédito' do
    balance = AiCreditBalance.create!(account_id: account.id, plan_credits: 5, extra_credits: 0)

    summary = described_class.new(conversation: conversation, reason: 'loop').generate

    expect(summary).to be_a(Ai::HandoffSummary)
    expect(summary.content).to eq('Cliente quer cancelar o plano.')
    expect(summary.reason).to eq('loop')
    expect(summary.run).to be_present

    run = Ai::Run.find_by(conversation_id: conversation.id, run_type: 'handoff_summary')
    expect(run).to be_present
    expect(run.mode).to eq('assistant')
    expect(run.cost).to eq(0.001) # custo registrado para os relatórios

    expect(balance.reload.total).to eq(5) # crédito NÃO foi consumido
  end

  it 'inclui o motivo do handoff e o transcript no prompt' do
    described_class.new(conversation: conversation, reason: 'credit_exhausted').generate

    expect(Ai::ModelRouter).to have_received(:decide) do |kwargs|
      expect(kwargs[:system_prompt]).to include('créditos de IA da conta se esgotaram')
      expect(kwargs[:user_message]).to include('quero cancelar meu plano')
      expect(kwargs[:json]).to be(true)
    end
  end

  it 'NÃO cria resumo quando a geração falha (status error)' do
    allow(Ai::ModelRouter).to receive(:decide).and_return(
      { provider: 'openai', model: 'gpt-4.1-mini', decision: { 'error' => 'boom' },
        tokens_in: 0, tokens_out: 0, cost: 0.0, latency_ms: 1, status: 'error' }
    )

    expect { described_class.new(conversation: conversation, reason: 'loop').generate }
      .not_to change(Ai::HandoffSummary, :count)
  end

  it 'devolve nil e não levanta quando o summary vem vazio' do
    allow(Ai::ModelRouter).to receive(:decide).and_return(
      { provider: 'openai', model: 'gpt-4.1-mini', decision: { 'summary' => '' },
        tokens_in: 1, tokens_out: 1, cost: 0.0, latency_ms: 1, status: 'recorded' }
    )

    expect(described_class.new(conversation: conversation, reason: 'loop').generate).to be_nil
  end
end
