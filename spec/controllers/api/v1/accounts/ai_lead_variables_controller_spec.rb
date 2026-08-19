require 'rails_helper'

RSpec.describe 'AI Lead Variables API', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) do
    profile = Ai::OperationProfile.create!(account_id: account.id, name: 'p', supervisor_provider: 'openai',
                                           supervisor_model: 'gpt-4.1-mini')
    Ai::Agent.create!(account: account, name: 'Bot', status: 'active', ai_operation_profile_id: profile.id)
  end
  let(:variable) { agent.lead_variables.create!(account: account, name: 'documento_cpf', var_type: 'texto') }

  def base_url
    "/api/v1/accounts/#{account.id}/ai_agents/#{agent.id}/ai_lead_variables"
  end

  describe 'POST create — normaliza e valida' do
    def create_var(name)
      post base_url, params: { ai_lead_variable: { name: name } }, headers: admin.create_new_auth_token, as: :json
    end

    it 'normaliza o nome no create (acento -> ASCII)' do
      create_var('número_conta')

      expect(response).to have_http_status(:created)
      expect(response.parsed_body['name']).to eq('numero_conta')
    end

    it 'rejeita (422) nome que normaliza para vazio' do
      create_var('@@@')

      expect(response).to have_http_status(:unprocessable_entity)
    end
  end

  describe 'DELETE destroy — guarda de "em uso"' do
    def delete_variable(var)
      delete "#{base_url}/#{var.id}", headers: admin.create_new_auth_token, as: :json
    end

    it 'exclui a variável quando NENHUMA etapa a usa' do
      agent.create_playbook!(active: true, steps: [{ 'name' => 'Outra', 'collect' => { 'attribute' => 'outra_chave' } }])

      delete_variable(variable)

      expect(response).to have_http_status(:no_content)
      expect(Ai::LeadVariable.exists?(variable.id)).to be(false)
    end

    it 'IMPEDE (422 com o nome da etapa) excluir variável EM USO por uma etapa' do
      agent.create_playbook!(active: true, steps: [{ 'name' => 'Cadastro CPF', 'collect' => { 'attribute' => 'documento_cpf' } }])

      delete_variable(variable)

      expect(response).to have_http_status(:unprocessable_entity)
      expect(response.parsed_body['errors'].join).to include('Cadastro CPF')
      expect(Ai::LeadVariable.exists?(variable.id)).to be(true) # não excluiu o metadado
    end
  end
end
