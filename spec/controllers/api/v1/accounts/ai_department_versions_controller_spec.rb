require 'rails_helper'

# Request coverage for the ai_department_versions endpoint: automatic snapshot on department update,
# listing, and restore (merge into behavior jsonb without wiping sibling keys).
RSpec.describe 'AI Department Versions API', type: :request do
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
                           behavior: { 'auto_attendance' => true, 'reply_scope' => 'all', 'max_replies' => 3 })
  end
  let(:fields) { Api::V1::Accounts::AiDepartmentsController::DEPARTMENT_BEHAVIOR_FIELDS }

  def base_path
    "/api/v1/accounts/#{account.id}/ai_agents/#{agent.id}/ai_departments/#{department.id}"
  end

  describe 'PATCH ai_departments/:id (snapshot trigger)' do
    it 'records a version on a successful update' do
      expect do
        patch base_path,
              params: { ai_department: { behavior: { auto_attendance: true, reply_scope: 'all', max_replies: 5 } } },
              headers: admin.create_new_auth_token, as: :json
      end.to change { Ai::Version.for_record(department).count }.by(1)
      expect(response).to have_http_status(:success)
    end

    it 'dedupes: a second identical update does not add another version' do
      patch base_path, params: { ai_department: { behavior: department.behavior } },
                       headers: admin.create_new_auth_token, as: :json
      expect do
        patch base_path, params: { ai_department: { behavior: department.behavior } },
                         headers: admin.create_new_auth_token, as: :json
      end.not_to(change { Ai::Version.for_record(department).count })
    end
  end

  describe 'GET ai_department_versions' do
    it 'lists versions newest-first in the shared { id, version_number, note, created_at } shape' do
      Ai::Version.snapshot!(department, snapshot_fields: fields)

      get "#{base_path}/ai_department_versions", headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body.first.keys).to match_array(%w[id version_number note created_at])
    end
  end

  describe 'POST ai_department_versions/:id/restore' do
    it 'restores behavior keys via merge, keeping sibling keys, and records a rollback version' do
      v1 = Ai::Version.snapshot!(department, snapshot_fields: fields)
      department.update!(behavior: department.behavior.merge('max_replies' => 9, 'reply_scope' => 'assigned',
                                                             'unrelated' => 'keep'))

      post "#{base_path}/ai_department_versions/#{v1.id}/restore",
           headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      department.reload
      expect(department.behavior['max_replies']).to eq(3)
      expect(department.behavior['reply_scope']).to eq('all')
      expect(department.behavior['unrelated']).to eq('keep')
      expect(Ai::Version.for_record(department).recent.first.note).to eq("Restaurado da v#{v1.version_number}")
    end

    it 'returns 404 for a version that does not belong to the department' do
      post "#{base_path}/ai_department_versions/999999/restore",
           headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:not_found)
    end
  end

  it 'requires authentication' do
    get "#{base_path}/ai_department_versions"

    expect(response).to have_http_status(:unauthorized)
  end
end
