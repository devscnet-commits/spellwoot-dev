require 'rails_helper'

# Grupo de WhatsApp: aba própria ("Grupos"), só humanos respondem, fora da distribuição automática, do CSAT e
# dos relatórios. Conversa com cliente segue como sempre.
RSpec.describe Conversation, 'group_chat (conversa de grupo)' do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:inbox) { create(:inbox, account: account) }
  let(:group_contact) { create(:contact, account: account, identifier: '120363405123456789@g.us') }
  let!(:group_conversation) { create(:conversation, account: account, inbox: inbox, contact: group_contact) }
  let!(:customer_conversation) { create(:conversation, account: account, inbox: inbox) }

  before do
    create(:inbox_member, user: admin, inbox: inbox)
    Current.account = account
  end

  describe 'listagem (ConversationFinder)' do
    def listed(params = {})
      ConversationFinder.new(admin, params).perform[:conversations].map(&:id)
    end

    it 'as abas normais não mostram grupo' do
      expect(listed).to contain_exactly(customer_conversation.id)
      expect(listed(inbox_id: inbox.id)).to contain_exactly(customer_conversation.id)
    end

    it 'a aba Grupos mostra só grupo' do
      expect(listed(conversation_type: 'group')).to contain_exactly(group_conversation.id)
    end

    it 'os contadores seguem a aba' do
      expect(ConversationFinder.new(admin, {}).perform_meta_only[:count][:all_count]).to eq(1)
      expect(ConversationFinder.new(admin, { conversation_type: 'group' }).perform_meta_only[:count][:all_count]).to eq(1)
    end
  end

  it 'o JSON da conversa informa group_chat (a lista do painel separa em tempo real)' do
    expect(group_conversation.push_event_data[:group_chat]).to be(true)
    expect(customer_conversation.push_event_data[:group_chat]).to be(false)
  end

  it 'grupo não entra na distribuição automática' do
    inbox.update!(enable_auto_assignment: true)
    expect(AutoAssignment::AgentAssignmentService).not_to receive(:new)

    create(:conversation, account: account, inbox: inbox, contact: group_contact)
  end

  it 'grupo não recebe pesquisa de satisfação' do
    inbox.update!(csat_survey_enabled: true)
    group_conversation.update!(status: :resolved)

    expect(CsatSurveyService.new(conversation: group_conversation).send(:should_send_csat_survey?)).to be(false)
  end

  it 'grupo não gera evento de relatório' do
    event = Events::Base.new('conversation.resolved', Time.zone.now, conversation: group_conversation)

    expect { ReportingEventListener.instance.conversation_resolved(event) }.not_to change(ReportingEvent, :count)
  end

  it 'o backfill marca os grupos que já existiam' do
    group_conversation.update_column(:group_chat, false) # rubocop:disable Rails/SkipsModelValidations

    Migration::BackfillGroupChatJob.perform_now

    expect(group_conversation.reload.group_chat).to be(true)
    expect(customer_conversation.reload.group_chat).to be(false)
  end
end
