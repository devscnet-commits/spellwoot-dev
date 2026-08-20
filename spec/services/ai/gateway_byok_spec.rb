require 'rails_helper'

# BYOK (billing Fase 3): quando a chave PRÓPRIA do cliente falha por auth (401), o Gateway aplica a tag
# 'chave-propria-falhou', refaz a decisão na chave global da SCNET e cobra 1 crédito SCNET desse retry.
RSpec.describe 'Ai::Gateway fallback BYOK', type: :model do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:profile) do
    Ai::OperationProfile.create!(account_id: account.id, name: 'balanceado',
                                 supervisor_provider: 'anthropic', supervisor_model: 'claude-3-5-sonnet-latest')
  end
  let(:agent) { Ai::Agent.create!(account: account, name: 'Bot', status: 'active', ai_operation_profile_id: profile.id) }

  before do
    account.enable_features!('ai_core')
    account.enable_features!('custom_llm_api_key')
    # Chave própria no Hub -> account_provider_key presente (a 1ª chamada usa a chave do cliente).
    IntegrationSetting.create!(account_id: account.id, provider: 'anthropic', enabled: true,
                               config: { 'apiKey' => 'sk-ant-cliente' }.to_json)

    allow_any_instance_of(::Inbox).to receive(:available_now?).and_return(true)
    allow(Ai::KnowledgeRetriever).to receive(:retrieve).and_return([])
    allow(Ai::Workers::MediaProcessor).to receive(:process).and_return(nil)
    agent.update!(behavior: { 'auto_attendance' => true, 'reply_scope' => 'all' })
    Ai::AgentInbox.create!(ai_agent_id: agent.id, inbox_id: inbox.id, mode: 'live', active: true)

    # 1ª decisão (chave própria) falha por auth; o retry (force_global_key) responde normal.
    allow(Ai::ModelRouter).to receive(:decide) do |**kwargs|
      if kwargs[:force_global_key]
        { provider: 'anthropic', model: 'claude-3-5-sonnet-latest',
          decision: { 'decision' => 'reply', 'reply_text' => 'oi, tudo bem?' },
          tokens_in: 1, tokens_out: 1, cost: 0.0, latency_ms: 1, status: 'recorded' }
      else
        { provider: 'anthropic', model: 'claude-3-5-sonnet-latest',
          decision: { 'error' => 'RubyLLM::UnauthorizedError: Invalid API key' },
          tokens_in: 0, tokens_out: 0, cost: 0.0, latency_ms: 1, status: 'error', error_type: 'auth_error' }
      end
    end
  end

  def run_gateway
    convo = create(:conversation, account: account, inbox: inbox, status: 'open')
    message = create(:message, account: account, inbox: inbox, conversation: convo, message_type: 'incoming', content: 'oi')
    binding = Ai::AgentInbox.find_by(ai_agent_id: agent.id, inbox_id: inbox.id)
    Ai::Gateway.new(message: message, agent_inbox: binding, mode: 'live').run
    convo
  end

  it 'aplica a tag chave-propria-falhou, refaz na chave global e responde ao cliente' do
    convo = run_gateway

    expect(convo.reload.label_list).to include('chave-propria-falhou')
    expect(Ai::Event.where(conversation_id: convo.id, event_type: 'decision.byok_fallback')).to exist
    expect(Ai::Event.where(conversation_id: convo.id, event_type: 'reply.sent')).to exist
    # força a chave global no retry (2ª chamada ao ModelRouter)
    expect(Ai::ModelRouter).to have_received(:decide).with(hash_including(force_global_key: true))
  end

  it 'cobra 1 crédito SCNET do retry quando há saldo' do
    AiCreditBalance.create!(account_id: account.id, plan_credits: 0, extra_credits: 5)

    run_gateway

    expect(account.ai_credit_balance.reload.total).to eq(4) # 1 crédito SCNET consumido no fallback
  end

  it 'auto-provisiona um AiCreditBalance zerado quando a conta BYOK ainda não tem um' do
    expect(account.ai_credit_balance).to be_nil

    convo = run_gateway

    expect(account.reload.ai_credit_balance).to be_present # criado no fallback
    expect(account.ai_credit_balance.total).to eq(0)       # zerado; sem saldo, consume é engolido
    expect(Ai::Event.where(conversation_id: convo.id, event_type: 'reply.sent')).to exist # resposta ainda saiu
  end
end
