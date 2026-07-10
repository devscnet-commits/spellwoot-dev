require 'rails_helper'

RSpec.describe 'AI Prompt Assistant API', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }

  before do
    allow(Ai::ModelRouter).to receive(:decide).and_return(
      { provider: 'openai', model: 'gpt-4.1-mini', decision: { 'suggestion' => 'ok' },
        tokens_in: 1, tokens_out: 1, cost: 0.0, latency_ms: 1, status: 'recorded' }
    )
  end

  def post_assistant(kind: 'base_prompt', brief: 'agente comercial de internet')
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
end
