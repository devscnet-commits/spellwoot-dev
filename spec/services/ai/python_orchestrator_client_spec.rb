require 'rails_helper'

# Cenário 1: valida a ponte Rails -> Python (Ai::Gateway substitui Ai::ContextBuilder + Ai::ModelRouter
# por esta chamada) inteiramente com WebMock — nenhum servidor Python real sobe, nenhum token da
# OpenAI é gasto (o "modelo" é só a resposta stubada abaixo).
RSpec.describe Ai::PythonOrchestratorClient do
  let(:account) { create(:account) }
  let(:conversation) { create(:conversation, account: account) }
  let(:operation_profile) do
    Ai::OperationProfile.create!(account: account, name: 'padrão', supervisor_provider: 'openai', supervisor_model: 'gpt-4o')
  end
  let(:agent) do
    Ai::Agent.create!(account: account, name: 'Assistente', ai_operation_profile_id: operation_profile.id,
                      base_prompt: 'Você ajuda clientes a fechar negócio.')
  end
  let(:department) do
    Ai::Department.create!(account: account, ai_agent_id: agent.id, name: 'Comercial', objetivo: 'Vender')
  end

  before do
    conversation.update!(additional_attributes: { 'openai_conversation_id' => 'resp_previous_123' })
  end

  def stub_orchestrator(status: 200, body: { reply: 'Olá! Como posso ajudar?', response_id: 'resp_novo_456' })
    stub_request(:post, described_class::ORCHESTRATOR_URL)
      .to_return(status: status, body: body.to_json, headers: { 'Content-Type' => 'application/json' })
  end

  describe '.build_orchestrator_url' do
    it 'acrescenta /process quando AI_ORCHESTRATOR_URL aponta só pra raiz do serviço (era o bug: POST em "/" -> 404)' do
      expect(described_class.build_orchestrator_url('http://ai-orchestrator:8000')).to eq('http://ai-orchestrator:8000/process')
    end

    it 'não duplica /process quando a env var já vem correta' do
      expect(described_class.build_orchestrator_url('http://ai-orchestrator:8000/process')).to eq('http://ai-orchestrator:8000/process')
    end

    it 'lida com barra final nos dois casos' do
      expect(described_class.build_orchestrator_url('http://ai-orchestrator:8000/')).to eq('http://ai-orchestrator:8000/process')
      expect(described_class.build_orchestrator_url('http://ai-orchestrator:8000/process/')).to eq('http://ai-orchestrator:8000/process')
    end
  end

  describe '.process_message' do
    it 'envia o payload compilado e devolve a resposta parseada — sem rede real, sem gastar tokens da OpenAI' do
      stub_orchestrator

      result = described_class.process_message(
        conversation: conversation, content: 'Quero saber o preço', agent: agent, department: department, mode: 'live'
      )

      expect(result).to eq(reply: 'Olá! Como posso ajudar?', response_id: 'resp_novo_456')
      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL)
        .with(body: hash_including(
          'ticket_id' => conversation.id,
          'ai_department_id' => department.id,
          'mode' => 'live',
          'user_input' => 'Quero saber o preço',
          # confirma que o histórico encadeia pelo previous_response_id já salvo — não reenvia um
          # blob de mensagens (é exatamente isso que substitui o HISTORY_LIMIT do Ai::ContextBuilder).
          'previous_response_id' => 'resp_previous_123',
          # multi-tenant: modelo do Ai::OperationProfile da account, não um valor fixo no .env do Python.
          'model' => 'gpt-4o',
          # temperature_position default (20) traduzido pelas âncoras 'openai' do TemperatureMapper.
          'temperature' => Ai::TemperatureMapper.resolve('openai', 20)
        ))
    end

    it 'manda model/temperature em branco quando o agente não tem operation_profile' do
      agent.update_column(:ai_operation_profile_id, nil)
      stub_orchestrator

      described_class.process_message(
        conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live'
      )

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL)
        .with(body: hash_including('model' => nil, 'temperature' => nil))
    end

    it 'nunca sobe uma exceção quando o orquestrador responde com erro — devolve reply em branco' do
      stub_orchestrator(status: 500, body: { error: 'boom' })

      result = described_class.process_message(
        conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live'
      )

      expect(result).to eq(reply: nil, response_id: nil)
    end

    it 'nunca sobe uma exceção em timeout de rede — devolve reply em branco' do
      stub_request(:post, described_class::ORCHESTRATOR_URL).to_timeout

      result = described_class.process_message(
        conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live'
      )

      expect(result).to eq(reply: nil, response_id: nil)
    end
  end

  # Etapa ATUAL (server-tracked ai_step_index) vira UMA tool de function-calling (Ai::StepCaptureTool)
  # + sua instrução vai pro system_prompt — nunca o playbook inteiro de uma vez (decisão explícita:
  # "Nunca mande todas as etapas juntas").
  describe 'etapa atual (ai_step_index) vira tools_schema + instrução no system_prompt' do
    it 'inclui a tool real do department JUNTO com a "registrar_<attribute>" SÓ da etapa ativa — e a instrução SÓ dela' do
      Ai::Playbook.create!(department: department, steps: [
        { 'name' => 'Boas-vindas', 'instructions' => 'Cumprimente com calor.' },
        { 'name' => 'Endereço', 'instructions' => 'Peça o endereço completo.',
          'collect' => { 'attribute' => 'endereco', 'type' => 'text' } }
      ])
      conversation.update!(additional_attributes: conversation.additional_attributes.merge('ai_step_index' => 1))
      Ai::Tool.create!(account: account, ai_department_id: department.id, name: 'conversation.add_label',
                       implementation_type: 'capability', capability_key: 'conversation.add_label', status: 'active')
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        body = JSON.parse(req.body)
        names = body['tools_schema'].map { |t| t['name'] }
        names.sort == %w[conversation.add_label registrar_endereco] &&
          body['system_prompt'].include?('Peça o endereço completo.') &&
          !body['system_prompt'].include?('Cumprimente com calor.')
      }
    end

    it 'etapa ativa sem collect (informativa): tools_schema só tem as tools reais, sem "Etapa atual" no prompt' do
      Ai::Playbook.create!(department: department, steps: [{ 'name' => 'Boas-vindas', 'instructions' => '' }])
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        body = JSON.parse(req.body)
        body['tools_schema'] == [] && !body['system_prompt'].include?('Etapa atual')
      }
    end

    it 'sem playbook, tools_schema e system_prompt ficam como hoje' do
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        body = JSON.parse(req.body)
        body['tools_schema'] == [] && !body['system_prompt'].include?('Etapa atual')
      }
    end
  end

  describe 'imagem do WhatsApp (image_url no payload)' do
    it 'inclui a URL real do anexo de imagem da mensagem, quando passada' do
      message = create(:message, conversation: conversation, account: account)
      attachment = message.attachments.create!(account: account, file_type: :image)
      allow(attachment).to receive(:download_url).and_return('https://cdn.example.com/foto.jpg')
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department,
                                      mode: 'live', message: message)

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL)
        .with(body: hash_including('image_url' => 'https://cdn.example.com/foto.jpg'))
    end

    it 'image_url vem nil quando não há mensagem/anexo de imagem' do
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL)
        .with(body: hash_including('image_url' => nil))
    end
  end
end
