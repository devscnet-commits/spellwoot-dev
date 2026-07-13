require 'rails_helper'

# Cobertura do versionamento do agente após a migração para o Ai::Version polimórfico: snapshot
# automático no create/update, listagem (shape enxuta) e restore (substitui os campos do agente).
RSpec.describe 'AI Agent Versions API', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:profile) do
    Ai::OperationProfile.create!(account_id: account.id, name: 'balanceado',
                                 supervisor_provider: 'openai', supervisor_model: 'gpt-4.1-mini')
  end
  let(:agent) do
    Ai::Agent.create!(account: account, name: 'Bot', status: 'active', ai_operation_profile_id: profile.id)
  end

  def agents_path
    "/api/v1/accounts/#{account.id}/ai_agents"
  end

  describe 'POST/PATCH ai_agents (gatilho de snapshot)' do
    it 'grava uma Ai::Version (versionable Ai::Agent) ao criar o agente' do
      # O before_action de limite de plano (Fase 2) chama FeatureGate, que depende de RequestStore
      # (indisponível neste path em teste — problema alheio a esta migração). Liberamos o limite para
      # exercitar o versionamento no create sem esbarrar nisso.
      allow(FeatureGate).to receive(:limit_action).and_return(:allow)

      expect do
        post agents_path,
             params: { ai_agent: { name: 'Novo', status: 'active', ai_operation_profile_id: profile.id } },
             headers: admin.create_new_auth_token, as: :json
      end.to change(Ai::Version, :count).by(1)

      expect(response).to have_http_status(:created)
      version = Ai::Version.recent.first
      expect(version.versionable_type).to eq('Ai::Agent')
    end

    it 'grava uma nova versão ao atualizar o agente' do
      agent # cria (sem versão automática — Ai::Agent.create! direto não passa pelo controller)
      expect do
        patch "#{agents_path}/#{agent.id}",
              params: { ai_agent: { base_prompt: 'novo prompt' } },
              headers: admin.create_new_auth_token, as: :json
      end.to change { Ai::Version.for_record(agent).count }.by(1)
      expect(response).to have_http_status(:success)
    end
  end

  describe 'GET ai_agent_versions' do
    it 'lista as versões newest-first na shape { id, version_number, note, created_at }' do
      Ai::Version.snapshot!(agent, snapshot_fields: Ai::Agent::SNAPSHOT_FIELDS)

      get "#{agents_path}/#{agent.id}/ai_agent_versions", headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body.first.keys).to match_array(%w[id version_number note created_at])
    end
  end

  describe 'POST ai_agent_versions/:id/restore' do
    it 'restaura os campos do agente (substituição) e grava a versão de rollback' do
      v1 = Ai::Version.snapshot!(agent, snapshot_fields: Ai::Agent::SNAPSHOT_FIELDS)
      agent.update!(base_prompt: 'prompt alterado', company_name: 'Nova Co')

      post "#{agents_path}/#{agent.id}/ai_agent_versions/#{v1.id}/restore",
           headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      agent.reload
      expect(agent.base_prompt).to be_nil       # v1 não tinha base_prompt -> substituído de volta
      expect(agent.company_name).to be_nil
      expect(Ai::Version.for_record(agent).recent.first.note).to eq("Restaurado da v#{v1.version_number}")
    end

    it 'retorna 404 para uma versão de outro agente' do
      other = Ai::Agent.create!(account: account, name: 'Outro', status: 'active', ai_operation_profile_id: profile.id)
      v = Ai::Version.snapshot!(other, snapshot_fields: Ai::Agent::SNAPSHOT_FIELDS)

      post "#{agents_path}/#{agent.id}/ai_agent_versions/#{v.id}/restore",
           headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:not_found)
    end
  end

  it 'exige autenticação' do
    get "#{agents_path}/#{agent.id}/ai_agent_versions"

    expect(response).to have_http_status(:unauthorized)
  end
end
