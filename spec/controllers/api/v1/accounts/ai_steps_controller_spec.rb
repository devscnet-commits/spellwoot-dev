require 'rails_helper'

RSpec.describe 'AI Steps API', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }

  def infer_slot(instructions)
    post "/api/v1/accounts/#{account.id}/ai_steps/infer_slot",
         params: { instructions: instructions }, headers: admin.create_new_auth_token, as: :json
  end

  it 'infere o slot da instrução (mesma lógica do Ai::StepSlot.infer)' do
    infer_slot('Grave endereco_completo com o texto fornecido.')

    expect(response).to have_http_status(:success)
    expect(response.parsed_body['attribute']).to eq('endereco_completo')
  end

  it 'devolve attribute nulo quando não há dado a coletar (etapa informativa)' do
    infer_slot('Apresente os planos disponíveis ao cliente.')

    expect(response).to have_http_status(:success)
    expect(response.parsed_body['attribute']).to be_nil
  end

  it 'exige autenticação' do
    post "/api/v1/accounts/#{account.id}/ai_steps/infer_slot", params: { instructions: 'x' }, as: :json

    expect(response).to have_http_status(:unauthorized)
  end
end
