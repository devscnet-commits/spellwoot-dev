require 'rails_helper'

# O que tira a IA de uma conversa. Achado ao vivo (Maya/Anderson): atendente atribuído e a IA seguia
# respondendo por 6 minutos — só parava na primeira mensagem humana.
RSpec.describe Ai::ReplyPolicy, '.human_control_reason' do
  let(:account) { create(:account) }
  let(:inbox) { create(:inbox, account: account) }
  let(:conversation) { create(:conversation, account: account, inbox: inbox) }
  let(:agent_user) { create(:user, account: account, role: :agent) }
  let(:profile) do
    Ai::OperationProfile.create!(account_id: account.id, name: 'balanceado',
                                 supervisor_provider: 'openai', supervisor_model: 'gpt-4.1-mini')
  end
  let(:ai_agent) do
    Ai::Agent.create!(account: account, name: 'Maya', status: 'active', ai_operation_profile_id: profile.id,
                      behavior: { 'reply_scope' => 'all', 'auto_attendance' => true })
  end

  before { create(:inbox_member, inbox: inbox, user: agent_user) }

  def allowed?
    described_class.allowed?(mode: 'live', agent: ai_agent, conversation: conversation)
  end

  def assign(headers)
    post "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/assignments",
         headers: headers, params: { assignee_id: agent_user.id }, as: :json
  end

  describe 'atribuição', type: :request do
    it 'pelo painel: a IA para' do
      assign(agent_user.create_new_auth_token)

      expect(conversation.reload.assignee_id).to eq(agent_user.id)
      expect(allowed?).to be(false)
      expect(described_class.skip_reason(mode: 'live', agent: ai_agent, conversation: conversation)).to eq('assigned_in_panel')
    end

    it 'por API/automação (n8n, Bitrix): a IA segue' do
      assign({ api_access_token: agent_user.access_token.token })

      expect(conversation.reload.assignee_id).to eq(agent_user.id)
      expect(allowed?).to be(true)
    end
  end

  it 'desativa_ia marcado: a IA para, até na mensagem do próprio handoff' do
    conversation.update!(custom_attributes: { 'desativa_ia' => true })

    expect(allowed?).to be(false)
    expect(described_class.allowed?(mode: 'live', agent: ai_agent, conversation: conversation, bypass_handoff: true)).to be(false)
    expect(described_class.skip_reason(mode: 'live', agent: ai_agent, conversation: conversation)).to eq('ai_disabled_attribute')
  end

  it 'lê o estado atual do banco, não o objeto carregado antes (janela do agrupamento)' do
    stale = Conversation.find(conversation.id)
    conversation.update!(custom_attributes: { 'desativa_ia' => true })

    expect(described_class.allowed?(mode: 'live', agent: ai_agent, conversation: stale)).to be(false)
  end

  it 'sem nada disso: a IA responde' do
    expect(allowed?).to be(true)
  end

  describe 'handoff da IA com atendente já na conversa' do
    it 'mantém o atendente em vez de devolver para a fila' do
      conversation.update!(assignee: agent_user)

      Ai::CapabilityRegistry.execute('conversation.transfer', conversation: conversation, input: { 'unassign' => true })

      expect(conversation.reload.assignee_id).to eq(agent_user.id)
    end

    it 'sem atendente segue como antes (desatribui)' do
      Ai::CapabilityRegistry.execute('conversation.transfer', conversation: conversation, input: { 'unassign' => true })

      expect(conversation.reload.assignee_id).to be_nil
    end
  end
end
