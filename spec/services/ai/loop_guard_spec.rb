require 'rails_helper'

RSpec.describe Ai::LoopGuard do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:profile) do
    Ai::OperationProfile.create!(account_id: account.id, name: 'balanceado',
                                 supervisor_provider: 'openai', supervisor_model: 'gpt-4.1-mini')
  end
  let(:agent) do
    Ai::Agent.create!(account: account, name: 'Bot', status: 'active', ai_operation_profile_id: profile.id)
  end

  # Dados REAIS do bug (medidos, não sintéticos): 3 paráfrases da mesma confirmação.
  R2 = 'Você mencionou que quer contratar internet para Cunha Porá, correto?'.freeze
  R1 = 'Você deseja contratar internet em Cunha Porá, correto?'.freeze
  NEW = 'Você está interessado em contratar internet em Cunha Porá, correto?'.freeze

  def reply_run(text, at)
    Ai::Run.create!(account_id: account.id, conversation_id: conversation.id, ai_agent_id: agent.id,
                    run_type: 'decision', mode: 'live', status: 'recorded',
                    decision: { 'decision' => 'reply', 'reply_text' => text }, created_at: at)
  end

  def incoming(at, content = 'sim')
    create(:message, account: account, inbox: inbox, conversation: conversation,
                     message_type: 'incoming', content: content, created_at: at)
  end

  subject(:guard) { described_class.new(conversation: conversation) }

  it 'detecta loop nas 3 paráfrases reais com incoming do cliente entre elas' do
    reply_run(R2, 6.minutes.ago)
    incoming(5.minutes.ago)
    reply_run(R1, 4.minutes.ago)
    incoming(3.minutes.ago)

    expect(guard.loop?(NEW)).to be(true)
  end

  it 'NÃO detecta loop quando não houve incoming do cliente entre as respostas (silêncio/follow-up)' do
    reply_run(R2, 6.minutes.ago)
    reply_run(R1, 4.minutes.ago) # sem incoming entre R2 e R1
    incoming(3.minutes.ago)

    expect(guard.loop?(NEW)).to be(false)
  end

  it 'NÃO detecta loop para respostas genuinamente diferentes' do
    reply_run('Para qual cidade você quer a instalação?', 6.minutes.ago)
    incoming(5.minutes.ago)
    reply_run('A forma de pagamento pode ser boleto ou cartão de crédito.', 4.minutes.ago)
    incoming(3.minutes.ago)

    expect(guard.loop?('Temos os planos Fibra 300, 500 e 1 Giga disponíveis.')).to be(false)
  end

  it 'NÃO detecta loop com menos de 2 respostas anteriores' do
    reply_run(R1, 4.minutes.ago)
    incoming(3.minutes.ago)

    expect(guard.loop?(NEW)).to be(false)
  end

  it 'exclui o run atual da comparação (current_run)' do
    reply_run(R2, 6.minutes.ago)
    incoming(5.minutes.ago)
    reply_run(R1, 4.minutes.ago)
    incoming(3.minutes.ago)
    current = reply_run(NEW, 1.minute.ago) # o run do turno atual, já com a decisão nova

    # com o run atual excluído, só R1 e R2 contam -> ainda detecta
    expect(described_class.new(conversation: conversation, current_run: current).loop?(NEW)).to be(true)
  end
end
