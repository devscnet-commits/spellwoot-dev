require 'rails_helper'

RSpec.describe Ai::KnowledgeRetryJob do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:profile) do
    Ai::OperationProfile.create!(account_id: account.id, name: 'padrão', supervisor_provider: 'openai', supervisor_model: 'gpt-4.1-mini')
  end
  let(:agent) { Ai::Agent.create!(account: account, name: 'Bot', status: 'active', ai_operation_profile_id: profile.id) }
  let(:binding) { Ai::AgentInbox.create!(ai_agent_id: agent.id, inbox_id: inbox.id, mode: 'live', active: true) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox, status: 'open') }
  let!(:message) do
    create(:message, account: account, inbox: inbox, conversation: conversation, message_type: 'incoming',
                     content: 'quanto custa o plano fibra?')
  end
  let(:gateway) { instance_double(Ai::Gateway, run: nil) }

  before { allow(Ai::Gateway).to receive(:new).and_return(gateway) }

  it 'roda a IA de novo para a mesma mensagem, pedindo para consultar e responder a pergunta pendente' do
    described_class.perform_now(message.id, binding.id, 2)

    expect(Ai::Gateway).to have_received(:new).with(
      message: message, agent_inbox: binding, mode: 'live',
      content_override: a_string_including('Consulte', 'quanto custa o plano fibra?'),
      knowledge_retry_attempt: 2
    )
    expect(gateway).to have_received(:run)
  end

  it 'não roda quando o cliente já mandou outra mensagem (o turno dela responde com o contexto novo)' do
    create(:message, account: account, inbox: inbox, conversation: conversation, message_type: 'incoming', content: 'e aí?')

    described_class.perform_now(message.id, binding.id, 1)

    expect(Ai::Gateway).not_to have_received(:new)
  end

  it 'não roda quando o agente foi desvinculado da caixa' do
    binding.update!(active: false)

    described_class.perform_now(message.id, binding.id, 1)

    expect(Ai::Gateway).not_to have_received(:new)
  end
end
