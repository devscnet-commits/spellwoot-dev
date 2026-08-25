require 'rails_helper'

# A aba "Atendimentos e transferências" (tela do AGENTE) cuida SÓ do mode (atende/não atende). A priority
# de eleição é decisão POR CAIXA entre agentes -> vive na tela da caixa (AiInboxAgentPriorities). Aqui o
# contrato é: o sync grava mode e PRESERVA a priority existente (não zera o que a tela da caixa gravou);
# binding novo herda o default 1 da coluna; "não atende" destrói o binding. Mutação por nome.
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

  describe 'sync do mode' do
    it 'grava o mode e o show o devolve (sem a chave priority nesta tela)' do
      sync([{ inbox_id: inbox.id, mode: 'live' }])
      expect(response).to have_http_status(:ok)
      expect(agent.agent_inboxes.find_by(inbox_id: inbox.id).mode).to eq('live')

      show
      aggregate_failures do
        expect(row_for(inbox.id)['mode']).to eq('live')
        expect(row_for(inbox.id)).not_to have_key('priority')
      end
    end

    it 'binding NOVO herda o default 1 da coluna (sem priority no payload)' do
      sync([{ inbox_id: inbox.id, mode: 'live' }])
      expect(agent.agent_inboxes.find_by(inbox_id: inbox.id).priority).to eq(1)
    end
  end

  describe 'PRESERVA a priority (gravada pela tela da caixa)' do
    it 'trocar o mode NÃO zera a priority existente' do
      Ai::AgentInbox.create!(ai_agent_id: agent.id, inbox_id: inbox.id, mode: 'live', active: true, priority: 5)
      # a tela do agente re-sincroniza o mesmo mode; a priority 5 (da tela da caixa) tem de sobreviver
      sync([{ inbox_id: inbox.id, mode: 'live' }])
      expect(agent.agent_inboxes.find_by(inbox_id: inbox.id).reload.priority).to eq(5)
    end

    it 'mudar live -> shadow preserva a priority' do
      Ai::AgentInbox.create!(ai_agent_id: agent.id, inbox_id: inbox.id, mode: 'live', active: true, priority: 4)
      sync([{ inbox_id: inbox.id, mode: 'shadow' }])
      binding = agent.agent_inboxes.find_by(inbox_id: inbox.id).reload
      aggregate_failures do
        expect(binding.mode).to eq('shadow')
        expect(binding.priority).to eq(4)
      end
    end
  end

  describe 'mode none' do
    it 'destrói o binding' do
      Ai::AgentInbox.create!(ai_agent_id: agent.id, inbox_id: inbox.id, mode: 'live', active: true, priority: 4)
      sync([{ inbox_id: inbox.id, mode: 'none' }])
      expect(agent.agent_inboxes.find_by(inbox_id: inbox.id)).to be_nil
    end
  end
end
