require 'rails_helper'

RSpec.describe 'AI Prompt Assistant API', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }

  before do
    # O serviço usa call_model (texto livre), NÃO decide (schema) — ver Ai::PromptAssistant / regressão #302.
    allow(Ai::ModelRouter).to receive(:call_model).and_return(
      { provider: 'openai', model: 'gpt-4.1-mini', text: '{"suggestion":"ok"}',
        tokens_in: 1, tokens_out: 1, status: 'recorded' }
    )
  end

  def post_assistant(kind: 'base_prompt', brief: 'agente de atendimento')
    post "/api/v1/accounts/#{account.id}/ai_prompt_assistant",
         params: { kind: kind, brief: brief }, headers: admin.create_new_auth_token, as: :json
  end

  it 'retorna a sugestão' do
    post_assistant

    expect(response).to have_http_status(:success)
    expect(response.parsed_body['suggestion']).to eq('ok')
  end

  it 'aplica throttle por conta acima do limite (429)' do
    Api::V1::Accounts::AiPromptAssistantController::RATE_LIMIT.times { post_assistant }

    post_assistant

    expect(response).to have_http_status(:too_many_requests)
  end

  it 'exige autenticação' do
    post "/api/v1/accounts/#{account.id}/ai_prompt_assistant", params: { kind: 'base_prompt', brief: 'x' }, as: :json

    expect(response).to have_http_status(:unauthorized)
  end

  # PR4 — o department ancora as capacidades reais. O controller SEMPRE escopa por conta: um id da conta
  # é carregado; um id de OUTRA conta vira nil (o service degrada). Nunca confia no id cru.
  describe 'department_id (escopo das capacidades)' do
    def make_department(acc)
      profile = Ai::OperationProfile.create!(account_id: acc.id, name: "p#{acc.id}", supervisor_provider: 'openai',
                                             supervisor_model: 'gpt-4.1-mini')
      agent = Ai::Agent.create!(account: acc, name: 'Bot', status: 'active', ai_operation_profile_id: profile.id)
      Ai::Department.create!(account: acc, ai_agent_id: agent.id, name: 'Fin', status: 'active', behavior: {})
    end

    def post_with_department(id)
      allow(Ai::PromptAssistant).to receive(:new).and_call_original
      post "/api/v1/accounts/#{account.id}/ai_prompt_assistant",
           params: { kind: 'step_instructions', brief: 'x', department_id: id },
           headers: admin.create_new_auth_token, as: :json
    end

    it 'carrega o department DA CONTA e passa ao serviço' do
      department = make_department(account)

      post_with_department(department.id)

      expect(Ai::PromptAssistant).to have_received(:new).with(hash_including(department: department))
    end

    it 'department de OUTRA conta NÃO é carregado (passa department: nil)' do
      foreign = make_department(create(:account))

      post_with_department(foreign.id)

      expect(Ai::PromptAssistant).to have_received(:new).with(hash_including(department: nil))
    end
  end
end
