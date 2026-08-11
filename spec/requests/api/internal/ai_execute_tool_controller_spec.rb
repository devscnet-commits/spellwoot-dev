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

  # Nome SANITIZADO — é isto que o Python realmente manda (Ai::PythonOrchestratorClient sanitiza todo
  # nome de tool antes de chegar na OpenAI; ver Ai::ToolNameSanitizer). O tool real no banco continua
  # com o ponto ('conversation.add_label') — o controller precisa resolver um pro outro.
  def call_webhook(headers: {})
    with_modified_env INTERNAL_AI_TOKEN: correct_token do
      post '/api/internal/ai_execute_tool',
           params: { ticket_id: conversation.id, ai_department_id: department.id, tool_name: 'conversation_add_label',
                      arguments: { label: 'Cliente em Negociação' }, mode: 'live' },
           headers: headers, as: :json
    end
  end

  describe 'POST /api/internal/ai_execute_tool' do
    context 'com o Bearer token correto (chamada simulada do Python pedindo o nome SANITIZADO conversation_add_label)' do
      it 'resolve "conversation_add_label" -> "conversation.add_label" e executa via Ai::ToolExecutor, devolve { result: ... }' do
        call_webhook(headers: { 'Authorization' => "Bearer #{correct_token}" })

        expect(response).to have_http_status(:success)
        # a etiqueta foi realmente persistida na conversa (não só "intencionada")
        expect(conversation.reload.label_list).to include('Cliente em Negociação')

        json = response.parsed_body
        expect(json['status']).to eq('executed')
        expect(json['result']).to be_present
        expect(json['result']['labels']).to include('Cliente em Negociação')
      end

      it 'tool desconhecida (não é controle, capture nem tool real — nem sanitizada nem não) devolve 404' do
        with_modified_env INTERNAL_AI_TOKEN: correct_token do
          post '/api/internal/ai_execute_tool',
               params: { ticket_id: conversation.id, ai_department_id: department.id, tool_name: 'tool_que_nao_existe',
                          arguments: {}, mode: 'live' },
               headers: { 'Authorization' => "Bearer #{correct_token}" }, as: :json
        end

        expect(response).to have_http_status(:not_found)
      end
    end

    def call_tool(tool_name, arguments: {}, mode: 'live')
      with_modified_env INTERNAL_AI_TOKEN: correct_token do
        post '/api/internal/ai_execute_tool',
             params: { ticket_id: conversation.id, ai_department_id: department.id, tool_name: tool_name,
                        arguments: arguments, mode: mode },
             headers: { 'Authorization' => "Bearer #{correct_token}" }, as: :json
      end
    end

    context 'chamada de uma capture tool "registrar_*" (Ai::StepCaptureTool — etapa do playbook, não uma Ai::Tool real)' do
      before do
        Ai::Playbook.create!(department: department,
                             steps: [{ 'name' => 'Endereço', 'collect' => { 'attribute' => 'endereco', 'type' => 'text' } }])
      end

      it 'grava o valor em ai_collected_facts via Ai::StateManager, SEM criar uma Ai::CapabilityExecution' do
        expect { call_tool('registrar_endereco', arguments: { endereco: 'Rua X, 123' }) }
          .not_to change(Ai::CapabilityExecution, :count)

        expect(response).to have_http_status(:success)
        expect(conversation.reload.additional_attributes['ai_collected_facts']).to eq('endereco' => 'Rua X, 123')
        json = response.parsed_body
        expect(json['status']).to eq('executed')
        expect(json['result']).to eq('endereco' => 'Rua X, 123')
      end

      it 'upsert: chamar de novo com outro valor ATUALIZA (não duplica)' do
        call_tool('registrar_endereco', arguments: { endereco: 'Rua X, 123' })
        call_tool('registrar_endereco', arguments: { endereco: 'Rua Y, 456' })

        expect(conversation.reload.additional_attributes['ai_collected_facts']).to eq('endereco' => 'Rua Y, 456')
      end

      it 'em modo shadow, NÃO grava nada (mesmo gate de Ai::ToolExecutor)' do
        call_tool('registrar_endereco', arguments: { endereco: 'Rua X, 123' }, mode: 'shadow')

        expect(response).to have_http_status(:success)
        expect(response.parsed_body['status']).to eq('skipped')
        expect(conversation.reload.additional_attributes['ai_collected_facts']).to be_nil
      end
    end

    context 'chamada de "avancar_etapa" (avanço agentic — a IA decide, não um índice travado)' do
      before do
        Ai::Playbook.create!(department: department, steps: [
          { 'name' => 'Boas-vindas' },
          { 'name' => 'Endereço', 'collect' => { 'attribute' => 'endereco' } },
          { 'name' => 'Fim' }
        ])
      end

      it 'incrementa ai_step_index e zera ai_step_turns' do
        conversation.update!(additional_attributes: { 'ai_step_index' => 0, 'ai_step_turns' => 3 })

        call_tool('avancar_etapa')

        expect(response).to have_http_status(:success)
        attrs = conversation.reload.additional_attributes
        expect(attrs['ai_step_index']).to eq(1)
        expect(attrs['ai_step_turns']).to eq(0)
        expect(response.parsed_body['status']).to eq('executed')
      end

      it 'trava na última etapa (não estoura o array)' do
        conversation.update!(additional_attributes: { 'ai_step_index' => 2 })

        call_tool('avancar_etapa')

        expect(conversation.reload.additional_attributes['ai_step_index']).to eq(2)
      end

      it 'em modo shadow, não avança nada' do
        conversation.update!(additional_attributes: { 'ai_step_index' => 0 })

        call_tool('avancar_etapa', mode: 'shadow')

        expect(conversation.reload.additional_attributes['ai_step_index']).to eq(0)
        expect(response.parsed_body['status']).to eq('skipped')
      end
    end

    context 'chamada de "salvar_memoria_ia" (catch-all de memória — híbrido com registrar_*)' do
      it 'grava chave/valor em ai_collected_facts via Ai::StateManager, SEM criar uma Ai::CapabilityExecution' do
        expect { call_tool('salvar_memoria_ia', arguments: { chave: 'nome_do_pet', valor: 'Rex' }) }
          .not_to change(Ai::CapabilityExecution, :count)

        expect(response).to have_http_status(:success)
        expect(conversation.reload.additional_attributes['ai_collected_facts']).to eq('nome_do_pet' => 'Rex')
        expect(response.parsed_body['status']).to eq('executed')
      end

      it 'upsert: chamar de novo com outro valor pra mesma chave ATUALIZA (não duplica)' do
        call_tool('salvar_memoria_ia', arguments: { chave: 'nome_do_pet', valor: 'Rex' })
        call_tool('salvar_memoria_ia', arguments: { chave: 'nome_do_pet', valor: 'Totó' })

        expect(conversation.reload.additional_attributes['ai_collected_facts']).to eq('nome_do_pet' => 'Totó')
      end

      it 'chave vazia/ausente não grava nada' do
        call_tool('salvar_memoria_ia', arguments: { valor: 'sem chave' })

        expect(response).to have_http_status(:success)
        expect(response.parsed_body['status']).to eq('skipped')
        expect(conversation.reload.additional_attributes['ai_collected_facts']).to be_nil
      end

      it 'em modo shadow, NÃO grava nada (mesmo gate de Ai::ToolExecutor)' do
        call_tool('salvar_memoria_ia', arguments: { chave: 'nome_do_pet', valor: 'Rex' }, mode: 'shadow')

        expect(response.parsed_body['status']).to eq('skipped')
        expect(conversation.reload.additional_attributes['ai_collected_facts']).to be_nil
      end

      it 'se a chave livre coincidir com um CustomAttributeDefinition real, espelha em custom_attributes igual a qualquer escrita :trusted (sem proteção especial)' do
        CustomAttributeDefinition.create!(account: account, attribute_key: 'cidade', attribute_display_name: 'Cidade',
                                          attribute_model: 'conversation_attribute', attribute_display_type: 'text')

        call_tool('salvar_memoria_ia', arguments: { chave: 'cidade', valor: 'Chapecó' })

        expect(conversation.reload.custom_attributes['cidade']).to eq('Chapecó')
      end
    end

    context 'chamada de "conversation.resolve"/"conversation.transfer" (tools de controle, sempre disponíveis)' do
      it 'conversation.resolve chama Ai::CapabilityRegistry e marca a conversa como resolvida' do
        call_tool('conversation_resolve')

        expect(response).to have_http_status(:success)
        expect(conversation.reload.status).to eq('resolved')
        expect(response.parsed_body['status']).to eq('executed')
      end

      it 'conversation.transfer chama Ai::CapabilityRegistry e reabre/desatribui a conversa' do
        conversation.update!(status: 'resolved', assignee_id: nil)

        call_tool('conversation_transfer')

        expect(response).to have_http_status(:success)
        expect(conversation.reload.status).to eq('open')
      end

      it 'conversation.transfer salva o handoff_summary da IA em additional_attributes' do
        call_tool('conversation_transfer', arguments: { handoff_summary: 'Cliente já forneceu nome e cidade, falta CPF' })

        expect(response).to have_http_status(:success)
        expect(conversation.reload.additional_attributes['handoff_summary'])
          .to eq('Cliente já forneceu nome e cidade, falta CPF')
      end

      it 'conversation.transfer sem handoff_summary (vazio/ausente) não grava nada, mas ainda transfere' do
        call_tool('conversation_transfer', arguments: {})

        expect(response).to have_http_status(:success)
        expect(conversation.reload.additional_attributes['handoff_summary']).to be_nil
      end

      it 'em modo shadow, não salva handoff_summary nem transfere (mesmo gate de live?)' do
        call_tool('conversation_transfer', arguments: { handoff_summary: 'não deveria salvar' }, mode: 'shadow')

        expect(conversation.reload.additional_attributes['handoff_summary']).to be_nil
        expect(response.parsed_body['status']).to eq('skipped')
      end

      it 'em modo shadow, nenhuma das duas muda a conversa' do
        call_tool('conversation_resolve', mode: 'shadow')

        expect(conversation.reload.status).to eq('open')
        expect(response.parsed_body['status']).to eq('skipped')
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
               params: { ticket_id: conversation.id, ai_department_id: other_department.id, tool_name: 'conversation_add_label',
                          arguments: { label: 'Cliente em Negociação' }, mode: 'live' },
               headers: { 'Authorization' => "Bearer #{correct_token}" }, as: :json
        end

        expect(response).to have_http_status(:forbidden)
        expect(conversation.reload.label_list).not_to include('Cliente em Negociação')
      end
    end
  end
end
