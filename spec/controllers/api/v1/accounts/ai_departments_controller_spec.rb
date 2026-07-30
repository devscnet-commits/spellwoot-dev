require 'rails_helper'

# Focused on the step automations[] validation added for the step-automation engine.
RSpec.describe 'AI Departments API — step automations validation', type: :request do
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
    Ai::Department.create!(account: account, ai_agent_id: agent.id, name: 'Atendimento', status: 'active', behavior: {})
  end

  def patch_steps(steps)
    patch "/api/v1/accounts/#{account.id}/ai_agents/#{agent.id}/ai_departments/#{department.id}",
          params: { ai_department: { playbook: { steps: steps } } },
          headers: admin.create_new_auth_token, as: :json
  end

  it 'rejects an unknown automation type with 422' do
    patch_steps([{ name: 'Coleta', automations: [{ type: 'foo', params: {} }] }])

    expect(response).to have_http_status(:unprocessable_entity)
  end

  it 'rejects a tag automation without label with 422' do
    patch_steps([{ name: 'Coleta', automations: [{ type: 'tag', params: {} }] }])

    expect(response).to have_http_status(:unprocessable_entity)
  end

  it 'rejects a change_team automation without team_id nor team_name' do
    patch_steps([{ name: 'Coleta', automations: [{ type: 'change_team', params: {} }] }])

    expect(response).to have_http_status(:unprocessable_entity)
  end

  it 'accepts valid automations and persists them in the playbook step' do
    patch_steps([{ name: 'Coleta', automations: [{ type: 'tag', params: { label: 'vip' } }] }])

    expect(response).to have_http_status(:success)
    step = department.reload.playbook.steps.first
    expect(step['automations'].first).to include('type' => 'tag')
    expect(step['automations'].first['params']).to include('label' => 'vip')
  end

  it 'accepts a step with no automations' do
    patch_steps([{ name: 'Coleta', instructions: 'oi' }])

    expect(response).to have_http_status(:success)
  end

  it 'accepts change_ai_department with a department_id and persists it' do
    target = Ai::Department.create!(account: account, ai_agent_id: agent.id, name: 'Vendas', status: 'active',
                                    behavior: {})
    patch_steps([{ name: 'Coleta',
                   automations: [{ type: 'change_ai_department', params: { department_id: target.id } }] }])

    expect(response).to have_http_status(:success)
    expect(department.reload.playbook.steps.first['automations'].first).to include('type' => 'change_ai_department')
  end

  it 'rejects change_ai_department without department_id' do
    patch_steps([{ name: 'Coleta', automations: [{ type: 'change_ai_department', params: {} }] }])

    expect(response).to have_http_status(:unprocessable_entity)
  end

  # (1) Guardrail contra sobrescrita CEGA do array de steps. lock_version defasado => 409 (o cliente
  # carregou antes de uma escrita out-of-band). Prova de mutação por nome.
  describe 'concorrência otimista do playbook (lock_version)' do
    def patch_with_lock(steps, lock_version)
      patch "/api/v1/accounts/#{account.id}/ai_agents/#{agent.id}/ai_departments/#{department.id}",
            params: { ai_department: { playbook: { steps: steps, lock_version: lock_version } } },
            headers: admin.create_new_auth_token, as: :json
    end

    it 'lock_version defasado => 409 e NÃO sobrescreve os steps' do
      patch_steps([{ name: 'Finalização' }]) # cria o playbook (sem on_complete ainda)
      base = department.reload.playbook.lock_version
      # escrita OUT-OF-BAND (ex.: console) ADICIONA on_complete -> muda de fato -> bumpa o lock_version
      department.playbook.update!(steps: [{ 'name' => 'Finalização', 'on_complete' => { 'action' => 'handoff_human' } }])
      expect(department.playbook.reload.lock_version).to be > base

      # o cliente (defasado, base antigo) tenta salvar SEM o on_complete -> deve ser BARRADO
      patch_with_lock([{ name: 'Finalização' }], base)

      aggregate_failures do
        expect(response).to have_http_status(:conflict)
        expect(department.playbook.reload.steps.first['on_complete']).to eq('action' => 'handoff_human') # intacto
      end
    end

    it 'lock_version ATUAL => grava e incrementa o lock_version' do
      patch_steps([{ name: 'Coleta' }])
      current = department.reload.playbook.lock_version

      patch_with_lock([{ name: 'Coleta' }, { name: 'Proposta' }], current)

      aggregate_failures do
        expect(response).to have_http_status(:success)
        expect(department.playbook.reload.steps.size).to eq(2)
        expect(department.playbook.lock_version).to be > current
      end
    end

    it 'sem lock_version no payload (save que não toca o playbook) NÃO é barrado' do
      patch_steps([{ name: 'Coleta' }]) # cria o playbook
      department.playbook.update!(steps: [{ 'name' => 'X' }]) # bumpa por fora

      patch_steps([{ name: 'Coleta' }]) # patch_steps não manda lock_version

      expect(response).to have_http_status(:success)
    end
  end
end
