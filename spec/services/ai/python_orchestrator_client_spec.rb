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
      # Auditoria de confiança: sem isto, um erro ANTES do HTTParty.post (ex.: exceção montando o
      # payload) cairia no MESMO rescue e devolveria o MESMO {reply: nil, response_id: nil} — o teste
      # passaria "por acidente" sem nunca ter tentado a requisição real. have_requested prova que o
      # POST aconteceu de verdade e que foi a resposta 500 do stub que produziu o resultado, não uma
      # exceção interna silenciosa.
      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL)
    end

    it 'nunca sobe uma exceção em timeout de rede — devolve reply em branco' do
      stub_request(:post, described_class::ORCHESTRATOR_URL).to_timeout

      result = described_class.process_message(
        conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live'
      )

      expect(result).to eq(reply: nil, response_id: nil)
      # Mesma auditoria: confirma que a requisição foi tentada (e o WebMock a interceptou para simular
      # o timeout), não que o código nunca chegou a discar.
      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL)
    end
  end

  # Fluxo agentic: TODAS as "registrar_*" (qualquer etapa do playbook) + as 3 tools de controle
  # (avancar_etapa/resolve/transfer) vão SEMPRE, sem gate por etapa ativa — a IA decide o que chamar.
  # A instrução no system_prompt continua ancorada só na etapa ATUAL (âncora narrativa, não trava nada).
  describe 'fluxo agentic: tools_schema traz TODAS as registrar_* + tools de controle sempre' do
    it 'inclui a tool real do department + TODAS as "registrar_<attribute>" do playbook + avancar_etapa/resolve/transfer' do
      Ai::Playbook.create!(department: department, steps: [
        { 'name' => 'Boas-vindas', 'instructions' => 'Cumprimente com calor.' },
        { 'name' => 'Endereço', 'instructions' => 'Peça o endereço completo.',
          'collect' => { 'attribute' => 'endereco', 'type' => 'text' } },
        { 'name' => 'Telefone extra', 'collect' => { 'attribute' => 'telefone_extra' } }
      ])
      conversation.update!(additional_attributes: conversation.additional_attributes.merge('ai_step_index' => 1))
      Ai::Tool.create!(account: account, ai_department_id: department.id, name: 'conversation.add_label',
                       implementation_type: 'capability', capability_key: 'conversation.add_label', status: 'active')
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        body = JSON.parse(req.body)
        names = body['tools_schema'].map { |t| t['name'] }
        # a instrução da etapa ATIVA (índice 1) aparece; a de OUTRA etapa (índice 0), não — só o texto
        # narrativo é ancorado na etapa atual, a captura de dado (tools) não é.
        names.sort == %w[avancar_etapa conversation.add_label conversation.resolve conversation.transfer
                          registrar_endereco registrar_telefone_extra].sort &&
          body['system_prompt'].include?('Peça o endereço completo.') &&
          !body['system_prompt'].include?('Cumprimente com calor.')
      }
    end

    it 'sem playbook, tools_schema ainda traz as 3 tools de controle (sempre disponíveis) mas nenhuma registrar_*' do
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        body = JSON.parse(req.body)
        names = body['tools_schema'].map { |t| t['name'] }
        names.sort == %w[avancar_etapa conversation.resolve conversation.transfer] &&
          !body['system_prompt'].include?('Etapa atual')
      }
    end
  end

  describe 'system_prompt traz encerramento/transferência configurados + instrução de tools' do
    it 'inclui transfer_when/close_when (do playbook) e a mensagem de encerramento (do department)' do
      Ai::Playbook.create!(department: department, transfer_when: ['cliente pede humano'],
                           close_when: ['cliente confirma que não quer mais nada'])
      department.update!(close_rules: { 'message' => 'Foi um prazer te atender!' })
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        prompt = JSON.parse(req.body)['system_prompt']
        prompt.include?('Transfira para humano quando: cliente pede humano.') &&
          prompt.include?('Encerre quando: cliente confirma que não quer mais nada.') &&
          prompt.include?('Foi um prazer te atender!') &&
          prompt.include?('conversation.resolve') &&
          prompt.include?('conversation.transfer')
      }
    end
  end

  describe 'force_handoff_notice (teto de segurança por etapa, decidido pelo Ai::Gateway)' do
    it 'quando true, injeta a instrução forçada de transferência imediata no system_prompt' do
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department,
                                      mode: 'live', force_handoff_notice: true)

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        JSON.parse(req.body)['system_prompt'].include?('LIMITE DE TENTATIVAS ATINGIDO')
      }
    end

    it 'default false — não injeta nada' do
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        !JSON.parse(req.body)['system_prompt'].include?('LIMITE DE TENTATIVAS ATINGIDO')
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

  # Fecha a lacuna de identidade (IA sugerindo concorrentes) + a base de conhecimento real deste
  # path (Ai::KnowledgeRetriever — pgvector já populado, NÃO o vector_store nativo da OpenAI, que
  # não existe: vector_store_id sempre vem vazio, auditado, sem tela/job que o preencha).
  describe 'identidade + conhecimento (Ai::KnowledgeRetriever) no system_prompt' do
    it 'a instrução de identidade é a PRIMEIRA linha do system_prompt, antes de qualquer outra coisa' do
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        JSON.parse(req.body)['system_prompt'].lines.first.include?('IDENTIDADE') &&
          JSON.parse(req.body)['system_prompt'].include?('É ESTRITAMENTE PROIBIDO sugerir que o cliente procure outras')
      }
    end

    it 'injeta os trechos retornados por Ai::KnowledgeRetriever num bloco "Conhecimento da empresa"' do
      allow(Ai::KnowledgeRetriever).to receive(:retrieve)
        .with(query: 'quanto custa o plano fibra?', account_id: account.id, department_id: department.id)
        .and_return(['Plano Fibra 500MB: R$ 99,90/mês', 'Plano Fibra 1GB: R$ 129,90/mês'])
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'quanto custa o plano fibra?',
                                      agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        prompt = JSON.parse(req.body)['system_prompt']
        prompt.include?('Conhecimento da empresa') &&
          prompt.include?('Plano Fibra 500MB: R$ 99,90/mês') &&
          prompt.include?('Plano Fibra 1GB: R$ 129,90/mês')
      }
    end

    it 'sem chunks (base vazia pra esse department), o bloco de conhecimento nem aparece' do
      allow(Ai::KnowledgeRetriever).to receive(:retrieve).and_return([])
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      # A instrução de IDENTIDADE já cita "Conhecimento da empresa" entre aspas (aponta pro bloco) —
      # checar essa substring simples daria falso positivo mesmo sem o bloco. O cabeçalho do bloco em
      # si ("...use para responder...") só existe quando knowledge_block realmente injeta algo.
      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        !JSON.parse(req.body)['system_prompt'].include?('Conhecimento da empresa (use para responder')
      }
    end

    it 'vector_store_id continua sendo lido de department.behavior e enviado (auditoria: sempre vazio na prática, mas o código está correto)' do
      department.update!(behavior: { 'vector_store_id' => 'vs_abc123' })
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL)
        .with(body: hash_including('vector_store_id' => 'vs_abc123'))
    end
  end
end
