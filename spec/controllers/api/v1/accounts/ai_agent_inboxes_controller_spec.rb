require 'rails_helper'

# Contrato do priority na aba "Atendimentos e transferências": a eleição de IA por caixa usa
# [priority ASC, id ASC] (fix/ai-agent-election). Antes deste PR o sync gravava só mode+active e o show
# devolvia só mode, então o priority ficava preso no default 1 para sempre. Aqui provamos o round-trip
# (grava e devolve), o default quando ausente, e que "Não atende" destrói o binding. Mutação por nome.
RSpec.describe 'AI Agent Inboxes API', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:profile) do
    Ai::OperationProfile.create!(account_id: account.id, name: 'balanceado',
                                 supervisor_provider: 'openai', supervisor_model: 'gpt-4.1-mini')
  end
  let(:agent) { Ai::Agent.create!(account: account, name: 'Bot', status: 'active', ai_operation_profile_id: profile.id) }
  let(:inbox) { create(:inbox, account: account) }

  def show
    get "/api/v1/accounts/#{account.id}/ai_agents/#{agent.id}/ai_agent_inboxes",
        headers: admin.create_new_auth_token, as: :json
  end

  def sync(bindings)
    put "/api/v1/accounts/#{account.id}/ai_agents/#{agent.id}/ai_agent_inboxes",
        params: { bindings: bindings }, headers: admin.create_new_auth_token, as: :json
  end

  def row_for(inbox_id)
    response.parsed_body.find { |r| r['inbox_id'] == inbox_id }
  end

  describe 'PUT round-trip do priority' do
    it 'grava o priority no binding e o show o devolve' do
      sync([{ inbox_id: inbox.id, mode: 'live', priority: 3 }])
      expect(response).to have_http_status(:ok)
      expect(agent.agent_inboxes.find_by(inbox_id: inbox.id).priority).to eq(3)

      show
      expect(row_for(inbox.id)['priority']).to eq(3)
    end

    it 'atualiza o priority de um binding já existente' do
      Ai::AgentInbox.create!(ai_agent_id: agent.id, inbox_id: inbox.id, mode: 'live', active: true, priority: 1)
      sync([{ inbox_id: inbox.id, mode: 'live', priority: 5 }])
      expect(agent.agent_inboxes.find_by(inbox_id: inbox.id).reload.priority).to eq(5)
    end
  end

  describe 'default do priority' do
    it 'grava 1 quando o priority vem ausente' do
      sync([{ inbox_id: inbox.id, mode: 'live' }])
      expect(agent.agent_inboxes.find_by(inbox_id: inbox.id).priority).to eq(1)
    end

    it 'cai no default 1 quando o priority é lixo ou menor que 1' do
      sync([{ inbox_id: inbox.id, mode: 'live', priority: 0 }])
      expect(agent.agent_inboxes.find_by(inbox_id: inbox.id).priority).to eq(1)
    end

    it 'show devolve priority 1 para caixa sem binding (Não atende)' do
      inbox # cria a caixa antes do show (let lazy); sem binding => mode none, priority default
      show
      expect(row_for(inbox.id)).to include('mode' => 'none', 'priority' => 1)
    end
  end

  describe 'mode none' do
    it 'destrói o binding (o priority some junto)' do
      Ai::AgentInbox.create!(ai_agent_id: agent.id, inbox_id: inbox.id, mode: 'live', active: true, priority: 4)
      sync([{ inbox_id: inbox.id, mode: 'none', priority: 4 }])
      expect(agent.agent_inboxes.find_by(inbox_id: inbox.id)).to be_nil
    end
  end
end
