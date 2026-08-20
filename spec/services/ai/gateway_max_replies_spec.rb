require 'rails_helper'

# max_replies: ao atingir o teto de respostas da IA, a conversa é TRANSFERIDA para humano
# (não mais silenciosa). Pré-check no Gateway antes de rodar o modelo — zero custo LLM.
RSpec.describe 'Ai::Gateway max_replies handoff', type: :model do
  let(:account) { create(:account) }
  let(:inbox)   { create(:inbox, account: account) }
  let(:profile) do
    Ai::OperationProfile.create!(account_id: account.id, name: 'p',
                                 supervisor_provider: 'openai', supervisor_model: 'gpt-4.1-mini')
  end
  let(:agent) do
    Ai::Agent.create!(account: account, name: 'Bot', status: 'active', ai_operation_profile_id: profile.id,
                      behavior: { 'auto_attendance' => true, 'reply_scope' => 'all', 'max_replies' => 3 })
  end

  before do
    Ai::AgentInbox.create!(ai_agent_id: agent.id, inbox_id: inbox.id, mode: 'live', active: true)
    allow_any_instance_of(::Inbox).to receive(:available_now?).and_return(true)
    allow(Ai::KnowledgeRetriever).to receive(:retrieve).and_return([])
    allow(Ai::Workers::MediaProcessor).to receive(:process).and_return(nil)
    allow(Ai::CapabilityRegistry).to receive(:execute).and_return({ output: {}, rollback_data: nil })
    allow(Ai::ModelRouter).to receive(:decide).and_return(
      { provider: 'openai', model: 'gpt-4.1-mini', decision: { 'decision' => 'reply', 'reply_text' => 'oi' },
        tokens_in: 1, tokens_out: 1, cost: 0.0, latency_ms: 1, status: 'recorded' }
    )
  end

  def run_gateway(convo)
    message = create(:message, account: account, inbox: inbox, conversation: convo,
                               message_type: 'incoming', content: 'oi')
    binding = Ai::AgentInbox.find_by(ai_agent_id: agent.id, inbox_id: inbox.id)
    Ai::Gateway.new(message: message, agent_inbox: binding, mode: 'live').run
  end

  def seed_ai_replies(convo, count)
    count.times do
      Ai::Event.create!(account_id: account.id, conversation_id: convo.id, ai_run_id: nil,
                        event_type: 'reply.sent', payload: { chars: 10 }, status: 'ok')
    end
  end

  context 'quando o teto NÃO foi atingido (2 de 3)' do
    it 'roda o modelo e responde normalmente' do
      convo = create(:conversation, account: account, inbox: inbox, status: 'open')
      seed_ai_replies(convo, 2)

      run_gateway(convo)

      expect(Ai::Run.last.status).to eq('recorded')
      expect(Ai::Event.where(conversation_id: convo.id, event_type: 'handoff.max_replies_reached')).to be_empty
    end
  end

  context 'quando o teto FOI atingido (3 de 3)' do
    let(:convo) { create(:conversation, account: account, inbox: inbox, status: 'open') }

    before { seed_ai_replies(convo, 3) }

    it 'finaliza o run com status max_replies' do
      run_gateway(convo)
      expect(Ai::Run.last.status).to eq('max_replies')
    end

    it 'emite handoff.max_replies_reached com o teto correto' do
      run_gateway(convo)
      event = Ai::Event.find_by(conversation_id: convo.id, event_type: 'handoff.max_replies_reached')
      expect(event).to be_present
      expect(event.payload['max']).to eq(3)
    end

    it 'NÃO chama o modelo (zero custo LLM)' do
      run_gateway(convo)
      expect(Ai::ModelRouter).not_to have_received(:decide)
    end

    it 'NÃO emite reply.sent (a IA não enviou nova resposta)' do
      expect do
        run_gateway(convo)
      end.not_to change { Ai::Event.where(conversation_id: convo.id, event_type: 'reply.sent').count }
    end

    it 'executa conversation.transfer (entrega ao time humano)' do
      run_gateway(convo)
      expect(Ai::CapabilityRegistry).to have_received(:execute)
        .with('conversation.transfer', hash_including(conversation: convo, input: hash_including('unassign' => true)))
    end

    it 'cria nota interna para o atendente (sem mensagem ao cliente)' do
      run_gateway(convo)
      note = convo.messages.reload.find { |m| m.private? }
      expect(note).to be_present
      expect(note.content).to include('3')
    end
  end

  context 'max_replies = 0 (desligado)' do
    before { agent.update!(behavior: agent.behavior.merge('max_replies' => 0)) }

    it 'não dispara o handoff mesmo com muitas respostas' do
      convo = create(:conversation, account: account, inbox: inbox, status: 'open')
      seed_ai_replies(convo, 100)

      run_gateway(convo)

      expect(Ai::Event.where(conversation_id: convo.id, event_type: 'handoff.max_replies_reached')).to be_empty
    end
  end
end
