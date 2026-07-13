require 'rails_helper'

# Cobertura do versionamento do PLAYBOOK após a migração para o Ai::Version polimórfico. PONTO
# CRÍTICO: o restore de steps (array) e default_messages (hash) SUBSTITUI o valor inteiro — nunca
# faz merge com o estado atual (preserva o comportamento antigo do Ai::PlaybookVersion).
RSpec.describe 'AI Playbook Versions API', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:profile) do
    Ai::OperationProfile.create!(account_id: account.id, name: 'balanceado',
                                 supervisor_provider: 'openai', supervisor_model: 'gpt-4.1-mini')
  end
  let(:agent) do
    Ai::Agent.create!(account: account, name: 'Bot', status: 'active', ai_operation_profile_id: profile.id)
  end
  let(:department) do
    Ai::Department.create!(account: account, ai_agent_id: agent.id, name: 'Atendimento', status: 'active',
                           behavior: { 'auto_attendance' => true })
  end

  def dept_path
    "/api/v1/accounts/#{account.id}/ai_agents/#{agent.id}/ai_departments/#{department.id}"
  end

  def upsert_playbook(steps:, default_messages: {})
    patch dept_path,
          params: { ai_department: { playbook: { objetivo: 'obj', steps: steps, default_messages: default_messages } } },
          headers: admin.create_new_auth_token, as: :json
  end

  describe 'PATCH ai_departments/:id com playbook (gatilho de snapshot)' do
    it 'grava uma Ai::Version com versionable Ai::Playbook' do
      expect do
        upsert_playbook(steps: [{ 'name' => 'a' }])
      end.to change { Ai::Version.where(versionable_type: 'Ai::Playbook').count }.by(1)
      expect(response).to have_http_status(:success)
    end
  end

  describe 'GET ai_playbook_versions' do
    it 'lista na shape { id, version_number, note, created_at }' do
      upsert_playbook(steps: [{ 'name' => 'a' }])

      get "#{dept_path}/ai_playbook_versions", headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body.first.keys).to match_array(%w[id version_number note created_at])
    end

    it 'retorna [] quando o department ainda não tem playbook' do
      get "#{dept_path}/ai_playbook_versions", headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body).to eq([])
    end
  end

  describe 'POST ai_playbook_versions/:id/restore (SUBSTITUIÇÃO, não merge)' do
    it 'restaura a lista INTEIRA de steps da v1 (não mistura com os steps novos)' do
      upsert_playbook(steps: [{ 'name' => 'a' }, { 'name' => 'b' }])
      playbook = department.reload.playbook
      v1 = Ai::Version.for_record(playbook).recent.first
      upsert_playbook(steps: [{ 'name' => 'x' }, { 'name' => 'y' }, { 'name' => 'z' }])

      post "#{dept_path}/ai_playbook_versions/#{v1.id}/restore",
           headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      expect(playbook.reload.steps).to eq([{ 'name' => 'a' }, { 'name' => 'b' }]) # exatamente a v1
    end

    it 'substitui default_messages inteiro (chaves que só existem no estado novo não sobrevivem)' do
      upsert_playbook(steps: [{ 'name' => 'a' }], default_messages: { 'greeting' => 'oi' })
      playbook = department.reload.playbook
      v1 = Ai::Version.for_record(playbook).recent.first
      upsert_playbook(steps: [{ 'name' => 'a' }], default_messages: { 'greeting' => 'hello', 'extra' => 'novo' })

      post "#{dept_path}/ai_playbook_versions/#{v1.id}/restore",
           headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      expect(playbook.reload.default_messages).to eq({ 'greeting' => 'oi' }) # 'extra' NÃO sobrevive
    end

    it 'grava a versão de rollback com a nota' do
      upsert_playbook(steps: [{ 'name' => 'a' }])
      playbook = department.reload.playbook
      v1 = Ai::Version.for_record(playbook).recent.first

      post "#{dept_path}/ai_playbook_versions/#{v1.id}/restore",
           headers: admin.create_new_auth_token, as: :json

      expect(Ai::Version.for_record(playbook).recent.first.note).to eq("Restaurado da v#{v1.version_number}")
    end

    it 'retorna 404 para uma versão inexistente' do
      upsert_playbook(steps: [{ 'name' => 'a' }])

      post "#{dept_path}/ai_playbook_versions/999999/restore",
           headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:not_found)
    end
  end
end
