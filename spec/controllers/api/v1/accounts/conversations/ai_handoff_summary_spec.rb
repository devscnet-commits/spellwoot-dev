require 'rails_helper'

RSpec.describe 'Conversation AI Handoff Summary API', type: :request do
  let(:account) { create(:account) }
  let(:agent) { create(:user, account: account, role: :agent) }
  let(:conversation) { create(:conversation, account: account) }

  before { create(:inbox_member, user: agent, inbox: conversation.inbox) }

  def path
    "/api/v1/accounts/#{account.id}/conversations/#{conversation.display_id}/ai_handoff_summary"
  end

  context 'quando não autenticado' do
    it 'retorna unauthorized' do
      get path
      expect(response).to have_http_status(:unauthorized)
    end
  end

  context 'quando a conversa ainda não teve handoff automático' do
    it 'retorna { summary: nil }' do
      get path, headers: agent.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['summary']).to be_nil
    end
  end

  context 'quando há resumos de handoff' do
    it 'retorna o mais recente com reason e created_at' do
      Ai::HandoffSummary.create!(account: account, conversation: conversation, reason: 'loop',
                                 content: 'resumo antigo', created_at: 2.hours.ago)
      Ai::HandoffSummary.create!(account: account, conversation: conversation, reason: 'credit_exhausted',
                                 content: 'resumo recente')

      get path, headers: agent.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body['summary']).to eq('resumo recente')
      expect(response.parsed_body['reason']).to eq('credit_exhausted')
      expect(response.parsed_body['created_at']).to be_present
    end
  end
end
