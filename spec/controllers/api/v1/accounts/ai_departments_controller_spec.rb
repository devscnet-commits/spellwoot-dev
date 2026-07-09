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
end
