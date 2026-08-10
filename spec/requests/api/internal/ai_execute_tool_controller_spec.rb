require 'rails_helper'

# Cenário 2 (execução) e Cenário 3 (segurança) da ponte Python -> Rails: simula o webhook que o
# orquestrador Python chama de volta para executar uma tool Rails-side, sem subir o Python real.
RSpec.describe 'Api::Internal::AiExecuteToolController', type: :request do
  let(:account) { create(:account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:operation_profile) do
    Ai::OperationProfile.create!(account: account, name: 'padrão', supervisor_provider: 'openai', supervisor_model: 'gpt-4o')
  end
  let(:agent) { Ai::Agent.create!(account: account, name: 'Assistente', ai_operation_profile_id: operation_profile.id) }
  let(:department) { Ai::Department.create!(account: account, ai_agent_id: agent.id, name: 'Comercial') }
  let!(:tool) do
    Ai::Tool.create!(account: account, ai_department_id: department.id, name: 'conversation.add_label',
                     implementation_type: 'capability', capability_key: 'conversation.add_label', status: 'active')
  end
  let(:correct_token) { 'internal-test-token' }

  def call_webhook(headers: {})
    with_modified_env INTERNAL_AI_TOKEN: correct_token do
      post '/api/internal/ai_execute_tool',
           params: { ticket_id: conversation.id, ai_department_id: department.id, tool_name: 'conversation.add_label',
                      arguments: { label: 'Cliente em Negociação' }, mode: 'live' },
           headers: headers, as: :json
    end
  end

  describe 'POST /api/internal/ai_execute_tool' do
    context 'com o Bearer token correto (chamada simulada do Python pedindo conversation.add_label)' do
      it 'executa a tool via Ai::ToolExecutor, adiciona a label na conversa e devolve { result: ... } para o Python continuar' do
        call_webhook(headers: { 'Authorization' => "Bearer #{correct_token}" })

        expect(response).to have_http_status(:success)
        # a etiqueta foi realmente persistida na conversa (não só "intencionada")
        expect(conversation.reload.label_list).to include('Cliente em Negociação')

        json = response.parsed_body
        expect(json['status']).to eq('executed')
        expect(json['result']).to be_present
        expect(json['result']['labels']).to include('Cliente em Negociação')
      end
    end

    context 'chamada de uma capture tool "registrar_*" (Ai::StepCaptureTool — etapa do playbook, não uma Ai::Tool real)' do
      it 'grava o valor em ai_collected_facts via Ai::StateManager, SEM criar uma Ai::CapabilityExecution' do
        Ai::Playbook.create!(department: department,
                             steps: [{ 'name' => 'Endereço', 'collect' => { 'attribute' => 'endereco', 'type' => 'text' } }])

        expect do
          with_modified_env INTERNAL_AI_TOKEN: correct_token do
            post '/api/internal/ai_execute_tool',
                 params: { ticket_id: conversation.id, ai_department_id: department.id, tool_name: 'registrar_endereco',
                            arguments: { endereco: 'Rua X, 123' }, mode: 'live' },
                 headers: { 'Authorization' => "Bearer #{correct_token}" }, as: :json
          end
        end.not_to change(Ai::CapabilityExecution, :count)

        expect(response).to have_http_status(:success)
        expect(conversation.reload.additional_attributes['ai_collected_facts']).to eq('endereco' => 'Rua X, 123')
        json = response.parsed_body
        expect(json['status']).to eq('executed')
        expect(json['result']).to eq('endereco' => 'Rua X, 123')
      end
    end

    context 'validação de segurança do webhook' do
      it 'retorna 401 quando nenhum Bearer token é enviado' do
        call_webhook(headers: {})

        expect(response).to have_http_status(:unauthorized)
        expect(conversation.reload.label_list).not_to include('Cliente em Negociação')
      end

      it 'retorna 401 quando o Bearer token é inválido' do
        call_webhook(headers: { 'Authorization' => 'Bearer token-invalido' })

        expect(response).to have_http_status(:unauthorized)
        expect(conversation.reload.label_list).not_to include('Cliente em Negociação')
      end

      it 'retorna 403 quando o ai_department_id não pertence à account do ticket_id (guard multi-tenant)' do
        other_account = create(:account)
        other_operation_profile = Ai::OperationProfile.create!(account: other_account, name: 'padrão',
                                                                supervisor_provider: 'openai', supervisor_model: 'gpt-4o')
        other_agent = Ai::Agent.create!(account: other_account, name: 'Assistente',
                                        ai_operation_profile_id: other_operation_profile.id)
        other_department = Ai::Department.create!(account: other_account, ai_agent_id: other_agent.id, name: 'Outra conta')

        with_modified_env INTERNAL_AI_TOKEN: correct_token do
          post '/api/internal/ai_execute_tool',
               params: { ticket_id: conversation.id, ai_department_id: other_department.id, tool_name: 'conversation.add_label',
                          arguments: { label: 'Cliente em Negociação' }, mode: 'live' },
               headers: { 'Authorization' => "Bearer #{correct_token}" }, as: :json
        end

        expect(response).to have_http_status(:forbidden)
        expect(conversation.reload.label_list).not_to include('Cliente em Negociação')
      end
    end
  end
end
