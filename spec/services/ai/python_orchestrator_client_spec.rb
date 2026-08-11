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
        # Checagem por INCLUSÃO, não igualdade exata do conjunto: toda Account real ganha um
        # CustomAttributeDefinition seedado automaticamente (Account#create_default_custom_attributes,
        # 'marcado_como_ganho_ou_perdido' — feature de Deals), então known_slot_keys sempre traz pelo
        # menos essa chave a mais — comportamento correto, não ruído a mascarar.
        # a instrução da etapa ATIVA (índice 1) aparece; a de OUTRA etapa (índice 0), não — só o texto
        # narrativo é ancorado na etapa atual, a captura de dado (tools) não é. Nomes SANITIZADOS
        # (Ai::ToolNameSanitizer): "conversation.add_label"/".resolve"/".transfer" viram "_" — a
        # OpenAI rejeita ponto no nome da function (achado ao vivo, ver spec do sanitizer).
        expected = %w[avancar_etapa conversation_add_label conversation_resolve conversation_transfer
                      registrar_endereco registrar_telefone_extra]
        expected.all? { |n| names.include?(n) } &&
          body['system_prompt'].include?('Peça o endereço completo.') &&
          !body['system_prompt'].include?('Cumprimente com calor.')
      }
    end

    # ACHADO AO VIVO: etapa 1 "Apresente-se" (sem collect) — só ela existir já bastava pra alucinação
    # se as demais etapas do playbook, mesmo declarando dado, não cobrissem tudo que a INSTRUÇÃO em
    # texto livre pedia. Aqui uma etapa pede "CPF, email e telefone" mas collect só nomeia 'cpf' —
    # email/telefone vêm de CustomAttributeDefinition (não de collect nenhum) e ainda assim precisam
    # de tool, senão a IA tem a instrução mas não o "botão" pra usar.
    it 'gera registrar_* pra atributo de CustomAttributeDefinition que NENHUMA etapa declara via collect' do
      CustomAttributeDefinition.create!(account: account, attribute_key: 'email', attribute_display_name: 'Email',
                                        attribute_model: 'conversation_attribute', attribute_display_type: 'text')
      CustomAttributeDefinition.create!(account: account, attribute_key: 'telefone', attribute_display_name: 'Telefone',
                                        attribute_model: 'conversation_attribute', attribute_display_type: 'text')
      Ai::Playbook.create!(department: department, steps: [
        { 'name' => 'Apresente-se', 'instructions' => 'Cumprimente o cliente.' }, # sem collect (etapa 1 do achado ao vivo)
        { 'name' => 'Coleta', 'instructions' => 'Colete CPF, email e telefone.',
          'collect' => { 'attribute' => 'cpf' } } # só CPF está no dropdown
      ])
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        names = JSON.parse(req.body)['tools_schema'].map { |t| t['name'] }
        %w[registrar_cpf registrar_email registrar_telefone].all? { |n| names.include?(n) }
      }
    end

    it 'sem playbook, tools_schema ainda traz as 4 tools de controle + o registrar_* do CustomAttributeDefinition padrão da conta (Deals) — nenhuma tool de etapa' do
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        body = JSON.parse(req.body)
        names = body['tools_schema'].map { |t| t['name'] }
        # 'marcado_como_ganho_ou_perdido' vem do CustomAttributeDefinition seedado em TODA Account
        # (Account#create_default_custom_attributes) — known_slot_keys inclui mesmo sem playbook.
        names.sort == %w[avancar_etapa conversation_resolve conversation_transfer salvar_memoria_ia
                          registrar_marcado_como_ganho_ou_perdido].sort &&
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
          prompt.include?('conversation_resolve') &&
          prompt.include?('conversation_transfer')
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
    it 'a instrução de identidade é a PRIMEIRA linha, e o guardrail anti-"médias de mercado" é a SEGUNDA' do
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        prompt_lines = JSON.parse(req.body)['system_prompt'].lines
        prompt_lines.first.include?('IDENTIDADE') &&
          prompt_lines.first.include?('É ESTRITAMENTE PROIBIDO sugerir que o cliente procure outras') &&
          prompt_lines[1].include?('Nunca cite concorrentes, médias de mercado')
      }
    end

    it 'injeta os trechos retornados por Ai::KnowledgeRetriever num bloco "CONHECIMENTO OFICIAL DA EMPRESA" agressivo/inegociável' do
      allow(Ai::KnowledgeRetriever).to receive(:retrieve)
        .with(query: 'quanto custa o plano fibra?', account_id: account.id, department_id: department.id)
        .and_return(['Plano Fibra 500MB: R$ 99,90/mês', 'Plano Fibra 1GB: R$ 129,90/mês'])
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'quanto custa o plano fibra?',
                                      agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        prompt = JSON.parse(req.body)['system_prompt']
        prompt.include?('## CONHECIMENTO OFICIAL DA EMPRESA') &&
          prompt.include?('É PROIBIDO usar conhecimento externo, médias de mercado ou suposições') &&
          prompt.include?('Plano Fibra 500MB: R$ 99,90/mês') &&
          prompt.include?('Plano Fibra 1GB: R$ 129,90/mês')
      }
    end

    it 'sem chunks (base vazia pra esse department), o bloco de conhecimento nem aparece' do
      allow(Ai::KnowledgeRetriever).to receive(:retrieve).and_return([])
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        !JSON.parse(req.body)['system_prompt'].include?('## CONHECIMENTO OFICIAL DA EMPRESA')
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

  # 4 falhas de comportamento achadas em teste ao vivo: IA "fingindo" ter chamado registrar_* sem
  # chamar de verdade, inventando situações/recursos que não existem, transferindo sem motivo (pulando
  # o fluxo de etapas), e empilhando várias perguntas de etapas diferentes na mesma mensagem.
  describe 'guardrails de comportamento (achados em teste ao vivo)' do
    it 'inclui as 5 instruções — chamar registrar_* de verdade, não fazer loop de confirmação, não inventar, disciplina de transferência, uma pergunta por vez' do
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        prompt = JSON.parse(req.body)['system_prompt']
        prompt.include?('É PROIBIDO dizer que "anotou" ou "registrou" sem chamar a tool') &&
          prompt.include?('REGRA DE AÇÃO IMEDIATA (OBRIGATÓRIO)') &&
          prompt.include?('É PROIBIDO inventar situações, recursos ou funcionalidades que não existem') &&
          prompt.include?('SÓ transfira para humano se') &&
          prompt.include?('Peça os dados da etapa atual UM DE CADA VEZ')
      }
    end

    # Bug real ao vivo (WhatsApp), 2 rodadas: cliente disse "vendas", a IA respondeu "Perfeito, é
    # vendas mesmo?" em loop, sem nunca chamar registrar_*/avancar_etapa. A 1ª instrução (mais curta)
    # não bastou — reforçada com passos numerados + o exemplo concreto "vendas". Guarda contra
    # REMOVER ou enfraquecer essa instrução de novo.
    it 'REGRA DE AÇÃO IMEDIATA: registrar_* + avancar_etapa nos 2 passos numerados, proibição explícita de confirmar, exemplo "vendas"' do
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'vendas', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        prompt = JSON.parse(req.body)['system_prompt']
        prompt.include?('REGRA DE AÇÃO IMEDIATA (OBRIGATÓRIO)') &&
          prompt.include?("1. Chamar a tool 'registrar_*' correspondente para salvar o dado IMEDIATAMENTE.") &&
          prompt.include?("2. Chamar a tool 'avancar_etapa' para avançar o fluxo.") &&
          prompt.include?("É ESTRITAMENTE PROIBIDO pedir confirmação ('é isso mesmo?', 'posso confirmar?')") &&
          prompt.include?("Se o cliente falou 'vendas', salve 'vendas' e avance") &&
          prompt.include?('Não responda apenas com texto, USE AS TOOLS')
      }
    end

    it 'NÃO inclui nenhuma instrução de "uma mensagem só" (múltiplas mensagens por turno é o modo identify_as="human", intencional)' do
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        !JSON.parse(req.body)['system_prompt'].include?('APENAS UMA mensagem por turno')
      }
    end
  end

  # Resumo de transferência: a tool conversation_transfer ganha um parâmetro obrigatório
  # handoff_summary — a IA preenche, o controller salva em additional_attributes['handoff_summary']
  # (ver spec/requests/api/internal/ai_execute_tool_controller_spec.rb pro lado da gravação).
  describe 'handoff_summary na tool conversation_transfer' do
    it 'conversation_transfer exige handoff_summary (string) no input_schema' do
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        transfer_tool = JSON.parse(req.body)['tools_schema'].find { |t| t['name'] == 'conversation_transfer' }
        transfer_tool['input_schema']['required'] == ['handoff_summary'] &&
          transfer_tool['input_schema']['properties']['handoff_summary']['type'] == 'string'
      }
    end

    it 'system_prompt instrui a IA a SEMPRE preencher handoff_summary ao transferir' do
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        JSON.parse(req.body)['system_prompt'].include?('você DEVE preencher o parâmetro "handoff_summary"')
      }
    end
  end

  # Híbrido (achado ao vivo, discutido com o usuário): "registrar_*" continua sendo a via pra
  # atributo JÁ conhecido (garante a chave exata pro espelhamento em custom_attributes);
  # "salvar_memoria_ia" é um catch-all pra QUALQUER outra coisa que o cliente informar, pra nunca
  # perder um dado só porque não existe uma tool dedicada pra ele.
  describe 'tool genérica "salvar_memoria_ia" (catch-all de memória)' do
    it 'sempre presente em tools_schema, com chave/valor string obrigatórios' do
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        tool = JSON.parse(req.body)['tools_schema'].find { |t| t['name'] == 'salvar_memoria_ia' }
        tool.present? &&
          tool['input_schema']['required'].sort == %w[chave valor] &&
          tool['input_schema']['properties']['chave']['type'] == 'string' &&
          tool['input_schema']['properties']['valor']['type'] == 'string'
      }
    end

    it 'system_prompt instrui a IA a usar salvar_memoria_ia quando não há registrar_* específica' do
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        JSON.parse(req.body)['system_prompt'].include?('use "salvar_memoria_ia" com chave=nome do dado')
      }
    end
  end
end
