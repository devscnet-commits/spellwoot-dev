require 'rails_helper'

# BYOK (billing Fase 3): quando a chave PRÓPRIA do cliente falha por auth (401), quem refaz o turno na
# chave global é o orquestrador Python (orchestrator.py) — desde a eliminação do motor legado o retry
# deixou de ser client-side. Ao Gateway cabe a contrapartida em Rails, que é o que este arquivo cobre:
# tag 'chave-propria-falhou' de visibilidade, evento decision.byok_fallback e 1 crédito SCNET cobrado
# pela chamada que teve de usar a chave da plataforma.
RSpec.describe 'Ai::Gateway fallback BYOK', type: :model do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  # openai, não anthropic: o discriminador de cobrança (Ai::Gateway#account_byok?) consulta a chave
  # de openai fixo, porque é o único provider que o orquestrador Python executa hoje. Num perfil de
  # outro provider a conta seria tratada como sem chave própria e o billing barraria o turno antes de
  # chegar ao fallback que este arquivo testa.
  let(:profile) do
    Ai::OperationProfile.create!(account_id: account.id, name: 'balanceado',
                                 supervisor_provider: 'openai', supervisor_model: 'gpt-4.1-mini')
  end
  let(:agent) { Ai::Agent.create!(account: account, name: 'Bot', status: 'active', ai_operation_profile_id: profile.id) }

  before do
    account.enable_features!('ai_core')
    enable_byok!(account)
    # Chave própria no Hub -> account_provider_key presente (a 1ª chamada usa a chave do cliente).
    IntegrationSetting.create!(account_id: account.id, provider: 'openai', enabled: true,
                               config: { 'apiKey' => 'sk-cliente' }.to_json)

    # available_now? só consulta horários quando working_hours_enabled? — desligado, ele responde
    # true sem stub nenhum. Explícito aqui porque o teste não é sobre horário de atendimento.
    inbox.update!(working_hours_enabled: false)
    allow(Ai::KnowledgeRetriever).to receive(:retrieve).and_return([])
    allow(Ai::Workers::MediaProcessor).to receive(:process).and_return(nil)
    agent.update!(behavior: { 'auto_attendance' => true, 'reply_scope' => 'all' })
    Ai::AgentInbox.create!(ai_agent_id: agent.id, inbox_id: inbox.id, mode: 'live', active: true)

    # O Python já tentou a chave da conta, tomou 401 e refez o turno na chave global: devolve a
    # resposta normalmente, com byok_fallback: true sinalizando que a plataforma pagou este turno.
    allow(Ai::PythonOrchestratorClient).to receive(:process_message).and_return(
      reply: 'oi, tudo bem?', conversation_id: 'conv_byok', byok_fallback: true,
      confidence: 0.9, transferred: false
    )
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
  end

  # Criar a assinatura já cria o saldo (Subscription#initialize_credit_balance), então aqui é update.
  it 'cobra 1 crédito SCNET do retry quando há saldo' do
    account.reload.ai_credit_balance.update!(plan_credits: 0, extra_credits: 5)

    run_gateway

    expect(account.ai_credit_balance.reload.total).to eq(4) # 1 crédito SCNET consumido no fallback
  end

  # find_or_create_by no #consume_byok_fallback_credit existe para a conta ANTIGA, cuja assinatura é
  # anterior ao Subscription#initialize_credit_balance e por isso nunca ganhou linha de saldo. É esse
  # estado que o destroy reproduz — hoje nenhuma assinatura nova nasce sem saldo.
  it 'auto-provisiona um AiCreditBalance zerado quando a conta BYOK ainda não tem um' do
    account.reload.ai_credit_balance.destroy!
    expect(account.reload.ai_credit_balance).to be_nil

    convo = run_gateway

    expect(account.reload.ai_credit_balance).to be_present # criado no fallback
    expect(account.ai_credit_balance.total).to eq(0)       # zerado; sem saldo, consume é engolido
    expect(Ai::Event.where(conversation_id: convo.id, event_type: 'reply.sent')).to exist # resposta ainda saiu
  end
end
