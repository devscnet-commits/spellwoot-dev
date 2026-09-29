require 'rails_helper'

# Grupo de WhatsApp: fica na aba "Grupos", só humanos respondem. A IA nunca responde — nem pela integração
# nativa UazAPI→Chatwoot, que cria o contato do grupo numa inbox API.
RSpec.describe Conversations::GroupDetector do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:group_contact) { create(:contact, account: account, identifier: '120363405123456789@g.us') }
  let(:group_conversation) { create(:conversation, account: account, inbox: inbox, contact: group_contact) }
  let(:customer_conversation) do
    create(:conversation, account: account, inbox: inbox, contact: create(:contact, account: account, phone_number: '+5549999990000'))
  end

  describe '.group?' do
    it 'grupo pelo identifier do contato' do
      expect(described_class.group?(group_conversation)).to be(true)
    end

    it 'grupo pelo source_id do contact_inbox' do
      customer_conversation.contact_inbox.update!(source_id: '120363405123456789@g.us')

      expect(described_class.group?(customer_conversation)).to be(true)
    end

    it 'conversa com cliente não é grupo' do
      expect(described_class.group?(customer_conversation)).to be(false)
    end

    it 'id numérico de grupo (sem @g.us) em inbox UazAPI é grupo' do
      channel = create(:channel_api, account: account, additional_attributes: { 'uazapi_instance_token' => 'tok' })
      contact = create(:contact, account: account, identifier: '120363405123456789')
      conversation = create(:conversation, account: account, inbox: channel.inbox, contact: contact)

      expect(described_class.group?(conversation)).to be(true)
    end

    it 'Facebook/Instagram: id do cliente com 16–17 dígitos NÃO é grupo' do
      stub_request(:post, /graph.facebook.com/)
      facebook_inbox = create(:inbox, account: account, channel: create(:channel_facebook_page, account: account))
      contact = create(:contact, account: account)
      contact_inbox = create(:contact_inbox, contact: contact, inbox: facebook_inbox, source_id: '24567891234567890')
      conversation = create(:conversation, account: account, inbox: facebook_inbox, contact: contact, contact_inbox: contact_inbox)

      expect(described_class.group?(conversation)).to be(false)
    end
  end

  describe 'marca na criação da conversa' do
    it 'conversa de grupo nasce com group_chat' do
      expect(group_conversation.group_chat).to be(true)
    end

    it 'conversa com cliente nasce sem group_chat' do
      expect(customer_conversation.group_chat).to be(false)
    end
  end

  describe 'barreiras da IA' do
    let(:profile) do
      Ai::OperationProfile.create!(account_id: account.id, name: 'balanceado',
                                   supervisor_provider: 'openai', supervisor_model: 'gpt-4.1-mini')
    end
    let(:agent) do
      Ai::Agent.create!(account: account, name: 'Bot', status: 'active', ai_operation_profile_id: profile.id,
                        behavior: { 'reply_scope' => 'all' })
    end

    it 'ReplyPolicy nunca libera resposta em grupo' do
      expect(Ai::ReplyPolicy.allowed?(mode: 'live', agent: agent, conversation: group_conversation)).to be(false)
      expect(Ai::ReplyPolicy.skip_reason(mode: 'live', agent: agent, conversation: group_conversation))
        .to eq('group_conversation')
      expect(Ai::ReplyPolicy.allowed?(mode: 'live', agent: agent, conversation: customer_conversation)).to be(true)
    end

    it 'o envio final não cria mensagem em grupo' do
      dispatcher = Ai::ActionDispatcher.new(conversation: group_conversation, account: account, agent: agent,
                                            mode: 'live', acts_live: true)

      expect { dispatcher.send(:send_message, 'olá') }.not_to(change { group_conversation.messages.count })
    end

    it 'partes agendadas também não saem para grupo' do
      expect { Ai::SplitReplyJob.perform_now(group_conversation.id, 'olá') }
        .not_to(change { group_conversation.messages.count })
    end

    it 'o Gateway não roda turno em grupo' do
      message = create(:message, conversation: group_conversation, account: account, inbox: inbox, message_type: :incoming)
      agent_inbox = Ai::AgentInbox.create!(ai_agent_id: agent.id, inbox_id: inbox.id,
                                           mode: 'live', active: true)

      expect { Ai::Gateway.new(message: message, agent_inbox: agent_inbox).run }.not_to change(Ai::Run, :count)
    end
  end
end
