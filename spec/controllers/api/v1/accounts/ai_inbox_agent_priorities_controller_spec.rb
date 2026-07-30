require 'rails_helper'

# Prioridade de eleição das IAs POR CAIXA (entre agentes). show lista os agentes atendentes ordenados como
# a eleição ([priority ASC, id ASC]); update grava o priority de cada um sem tocar mode. Mutação por nome.
RSpec.describe 'AI Inbox Agent Priorities API', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:profile) do
    Ai::OperationProfile.create!(account_id: account.id, name: 'balanceado',
                                 supervisor_provider: 'openai', supervisor_model: 'gpt-4.1-mini')
  end
  let(:inbox) { create(:inbox, account: account) }
  let(:maya) { Ai::Agent.create!(account: account, name: 'Maya', status: 'active', ai_operation_profile_id: profile.id) }
  let(:cris) { Ai::Agent.create!(account: account, name: 'Cris', status: 'active', ai_operation_profile_id: profile.id) }

  def bind(agent, mode: 'live', priority: 1)
    Ai::AgentInbox.create!(ai_agent_id: agent.id, inbox_id: inbox.id, mode: mode, active: true, priority: priority)
  end

  def show
    get "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}/ai_agent_priorities",
        headers: admin.create_new_auth_token, as: :json
  end

  def update(priorities)
    patch "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}/ai_agent_priorities",
          params: { priorities: priorities }, headers: admin.create_new_auth_token, as: :json
  end

  describe 'show' do
    it 'lista os agentes atendentes com nome/mode/priority, ordenados por [priority, id]' do
      bind(maya, priority: 2)
      bind(cris, priority: 1)
      show
      expect(response).to have_http_status(:success)
      body = response.parsed_body
      aggregate_failures do
        expect(body.map { |a| a['agent_id'] }).to eq([cris.id, maya.id]) # menor priority primeiro
        expect(body.first).to include('agent_name' => 'Cris', 'mode' => 'live', 'priority' => 1)
      end
    end

    it 'não lista caixa sem agentes atendendo' do
      show
      expect(response.parsed_body).to eq([])
    end
  end

  describe 'update' do
    it 'grava o priority de cada agente sem tocar o mode' do
      bind(maya, mode: 'live', priority: 1)
      bind(cris, mode: 'live', priority: 1)
      update([{ agent_id: maya.id, priority: 1 }, { agent_id: cris.id, priority: 2 }])
      aggregate_failures do
        expect(response).to have_http_status(:ok)
        expect(maya.agent_inboxes.find_by(inbox_id: inbox.id).priority).to eq(1)
        expect(cris.agent_inboxes.find_by(inbox_id: inbox.id).reload.priority).to eq(2)
        expect(cris.agent_inboxes.find_by(inbox_id: inbox.id).mode).to eq('live') # mode intocado
      end
    end

    it 'sanitiza: priority lixo/menor que 1 cai no default 1' do
      bind(maya, priority: 3)
      update([{ agent_id: maya.id, priority: 0 }])
      expect(maya.agent_inboxes.find_by(inbox_id: inbox.id).reload.priority).to eq(1)
    end

    it 'ignora agent_id que não tem binding nesta caixa' do
      bind(maya, priority: 1)
      update([{ agent_id: cris.id, priority: 9 }]) # cris não atende esta caixa
      expect(response).to have_http_status(:ok)
      expect(cris.agent_inboxes.find_by(inbox_id: inbox.id)).to be_nil
    end
  end

  it 'caixa inexistente -> 404' do
    get "/api/v1/accounts/#{account.id}/inboxes/0/ai_agent_priorities",
        headers: admin.create_new_auth_token, as: :json
    expect(response).to have_http_status(:not_found)
  end
end
