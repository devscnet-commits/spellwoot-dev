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
    conversation.update!(additional_attributes: { 'openai_conversation_id' => 'conv_previous_123' })
  end

  def stub_orchestrator(status: 200, body: { reply: 'Olá! Como posso ajudar?', conversation_id: 'conv_novo_456' })
    stub_request(:post, described_class::ORCHESTRATOR_URL)
      .to_return(status: status, body: body.to_json, headers: { 'Content-Type' => 'application/json' })
  end

  # Cadastra conhecimento pro department (fonte + chunk já indexado) — mesmo shape de
  # spec/services/ai/knowledge_retriever_spec.rb. Sem isto, NENHUM teste deste arquivo tem
  # #has_knowledge? true (a conta/department de teste não nasce com nenhum Ai::KnowledgeSource).
  def add_knowledge!(content: 'Atendemos de segunda a sexta, das 9h às 18h.')
    allow(Ai::KnowledgeIngestJob).to receive(:perform_later)
    source = Ai::KnowledgeSource.create!(account: account, ai_department_id: department.id, kind: 'faq', title: 'FAQ')
    Ai::KnowledgeChunk.create!(ai_knowledge_source_id: source.id, content: content, embedding: nil)
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

      expect(result).to eq(reply: 'Olá! Como posso ajudar?', conversation_id: 'conv_novo_456', byok_fallback: false)
      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL)
        .with(body: hash_including(
          'ticket_id' => conversation.id,
          'ai_department_id' => department.id,
          'mode' => 'live',
          'user_input' => 'Quero saber o preço',
          # confirma que o histórico encadeia pela OpenAI Conversation já salva — não reenvia um
          # blob de mensagens (é exatamente isso que substitui o HISTORY_LIMIT do Ai::ContextBuilder).
          'conversation_id' => 'conv_previous_123',
          # multi-tenant: modelo do Ai::OperationProfile da account, não um valor fixo no .env do Python.
          'model' => 'gpt-4o',
          # trafega desde já (Python só loga, ainda sem dispatch por provider — ver orchestrator.py).
          'provider' => 'openai',
          # temperature_position default (20) traduzido pelas âncoras 'openai' do TemperatureMapper.
          'temperature' => Ai::TemperatureMapper.resolve('openai', 20)
        ))
    end

    it 'manda model/provider/temperature em branco quando o agente não tem operation_profile' do
      agent.update_column(:ai_operation_profile_id, nil)
      stub_orchestrator

      described_class.process_message(
        conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live'
      )

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL)
        .with(body: hash_including('model' => nil, 'provider' => nil, 'temperature' => nil))
    end

    it 'nunca sobe uma exceção quando o orquestrador responde com erro — devolve reply em branco' do
      stub_orchestrator(status: 500, body: { error: 'boom' })

      result = described_class.process_message(
        conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live'
      )

      expect(result).to eq(reply: nil, conversation_id: nil, byok_fallback: false)
      # Auditoria de confiança: sem isto, um erro ANTES do HTTParty.post (ex.: exceção montando o
      # payload) cairia no MESMO rescue e devolveria o MESMO {reply: nil, conversation_id: nil} — o teste
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

      expect(result).to eq(reply: nil, conversation_id: nil, byok_fallback: false)
      # Mesma auditoria: confirma que a requisição foi tentada (e o WebMock a interceptou para simular
      # o timeout), não que o código nunca chegou a discar.
      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL)
    end
  end

  # BYOK (billing Fase 3): GAP achado em auditoria (13/08) — o orquestrador Python nunca recebia
  # NENHUMA chave por request antes desta mudança, sempre a global fixa; uma conta com BYOK ligado
  # consumia a chave/cota da SCNET em silêncio. account_api_key só vai preenchido quando a conta tem a
  # feature custom_llm_api_key ligada E uma chave de verdade salva no Hub (Ai::ModelRouter.account_provider_key).
  describe 'BYOK (account_api_key no payload + byok_fallback na resposta)' do
    it 'manda account_api_key quando a conta tem custom_llm_api_key ligado com chave openai configurada' do
      account.enable_features!('custom_llm_api_key')
      allow(Ai::ModelRouter).to receive(:account_provider_key).with(account.id, 'openai').and_return('sk-conta-propria')
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL)
        .with(body: hash_including('account_api_key' => 'sk-conta-propria'))
    end

    it 'manda account_api_key nil quando a conta NÃO tem a feature ligada (comportamento de sempre)' do
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL)
        .with(body: hash_including('account_api_key' => nil))
    end

    it 'devolve byok_fallback: true quando o Python avisa que a chave própria falhou e caiu pra global' do
      stub_orchestrator(body: { reply: 'oi', conversation_id: 'conv_1', byok_fallback: true })

      result = described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(result[:byok_fallback]).to be true
    end

    it 'devolve byok_fallback: false quando o Python não manda o campo (retrocompat)' do
      stub_orchestrator(body: { reply: 'oi', conversation_id: 'conv_1' })

      result = described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(result[:byok_fallback]).to be false
    end
  end

  # Achado 14/08 (ticket 563, Frente 1): a análise de compactação de prompt usou o playbook real do
  # Department 5 (Maya v5.0, provedor de internet — etapas "VIABILIDADE", "PLANOS", atributos
  # "cidade"/"documento_cpf"/etc.) como CASO DE TESTE, não como molde — o sistema é multi-cliente
  # configurável. Este teste prova que o renderizador (Ai::StepInstructionText +
  # #step_extraction_instruction/#data_validation_instruction/#current_step_instructions/
  # #next_step_instructions) é 100% genérico: um playbook de domínio TOTALMENTE alheio (pedido de
  # pizza — zero overlap de vocabulário com a Maya) produz a MESMA estrutura de blocos, sem nenhum
  # hardcode de nome de etapa ou atributo escondido no meio do caminho.
  describe 'renderização de etapa é 100% genérica (achado 14/08, validação da Frente 1)' do
    it 'produz a mesma estrutura de blocos pra um playbook de domínio completamente diferente do da Maya' do
      Ai::Playbook.create!(department: department, steps: [
        { 'name' => 'sabor', 'objective' => 'Descobrir o sabor da pizza que o cliente quer.',
          'rules' => ['Se o cliente pedir "surpresa", sugira o sabor mais vendido do dia.'],
          'collect' => { 'attribute' => 'sabor_pizza', 'type' => 'text' } },
        { 'name' => 'entrega', 'objective' => 'Confirmar o endereço de entrega.',
          'collect' => { 'attribute' => 'endereco_entrega', 'type' => 'text' } }
      ])
      conversation.update!(additional_attributes: conversation.additional_attributes.merge('ai_step_index' => 0))

      captured = []
      stub_request(:post, described_class::ORCHESTRATOR_URL).to_return do |request|
        captured << JSON.parse(request.body)['system_prompt']
        { status: 200, body: { reply: 'ok', conversation_id: 'conv_pizza' }.to_json,
          headers: { 'Content-Type' => 'application/json' } }
      end

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')
      prompt = captured.first

      # Mesma FORMA de blocos que qualquer playbook (Maya inclusa) produziria — objective/rules
      # (Ai::StepInstructionText), extração JSON, validação de foco, próxima etapa.
      expect(prompt).to include('ETAPA ATUAL:')
      expect(prompt).to include('Objetivo: Descobrir o sabor da pizza que o cliente quer.')
      expect(prompt).to include('Regras:')
      expect(prompt).to include('- Se o cliente pedir "surpresa", sugira o sabor mais vendido do dia.')
      expect(prompt).to include("REGRA DE EXTRAÇÃO JSON: Nesta etapa, você deve extrair o dado referente a 'sabor_pizza'")
      expect(prompt).to include('REGRAS DE FOCO E VALIDAÇÃO DA COLETA')
      expect(prompt).to include('PRÓXIMA ETAPA')
      expect(prompt).to include('Confirmar o endereço de entrega.')

      # Nenhum vocabulário da Maya vaza pro prompt de um playbook que nunca o declarou -- prova de que
      # não há fallback/hardcode escondido puxando texto de outro domínio. "cidade" sozinho fica de
      # fora de propósito: aparece como exemplo ilustrativo genérico dentro de
      # #structured_output_instruction (estático, IDÊNTICO pra qualquer department, não lido dos dados
      # do playbook) — coincidência de vocabulário, não hardcode; os nomes compostos abaixo não têm
      # esse risco de falso positivo.
      %w[viabilidade plano_escolhido documento_cpf aparelhos_conectados tamanho_imovel].each do |maya_word|
        expect(prompt).not_to include(maya_word)
      end
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
        # consultar_conhecimento fica de fora daqui de propósito: é condicional a haver conhecimento
        # cadastrado pro department (#has_knowledge?), coberto no describe próprio abaixo — esta conta
        # de teste não cadastra nenhum Ai::KnowledgeSource.
        expected = %w[avancar_etapa continuar_conversa conversation_add_label
                      conversation_resolve conversation_transfer registrar_endereco registrar_telefone_extra]
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

    it 'sem playbook, tools_schema ainda traz as 5 tools de controle + o registrar_* do CustomAttributeDefinition padrão da conta (Deals) — nenhuma tool de etapa' do
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        body = JSON.parse(req.body)
        names = body['tools_schema'].map { |t| t['name'] }
        # 'marcado_como_ganho_ou_perdido' vem do CustomAttributeDefinition seedado em TODA Account
        # (Account#create_default_custom_attributes) — known_slot_keys inclui mesmo sem playbook.
        # continuar_conversa: no-op que sustenta tool_choice="required" no orchestrator.py.
        # consultar_conhecimento fica de fora: esta conta não tem nenhum Ai::KnowledgeSource cadastrado
        # (#has_knowledge? false) — ver describe próprio abaixo.
        names.sort == %w[avancar_etapa continuar_conversa conversation_resolve
                          conversation_transfer salvar_memoria_ia registrar_marcado_como_ganho_ou_perdido].sort &&
          !body['system_prompt'].include?('Etapa atual')
      }
    end
  end

  # Pedido do usuário: mesmo padrão achado no fluxo n8n Maya v4.0 — manda objetivo + texto da PRÓXIMA
  # etapa junto no system_prompt, não só a atual. Reusa Ai::StateManager#next_step (já existia pro
  # look-ahead de conhecimento do motor legado).
  describe 'PRÓXIMA ETAPA no system_prompt (next_step_instructions)' do
    it 'inclui a próxima etapa, DEPOIS da ETAPA ATUAL, quando existe uma' do
      Ai::Playbook.create!(department: department, steps: [
        { 'name' => 'Boas-vindas', 'objective' => 'Cumprimentar.' },
        { 'name' => 'CPF', 'objective' => 'Peça o CPF.', 'collect' => { 'attribute' => 'cpf' } },
        { 'name' => 'Endereço', 'objective' => 'Peça o endereço.' }
      ])
      conversation.update!(additional_attributes: conversation.additional_attributes.merge('ai_step_index' => 1))
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        prompt = JSON.parse(req.body)['system_prompt']
        atual_idx = prompt.index('ETAPA ATUAL')
        proxima_idx = prompt.index('PRÓXIMA ETAPA')
        prompt.include?('Peça o CPF.') && # etapa atual (índice 1)
          prompt.include?('Peça o endereço.') && # próxima etapa (índice 2)
          atual_idx.present? && proxima_idx.present? && atual_idx < proxima_idx
      }
    end

    it 'NÃO trava o avanço nem a captura — o texto deixa claro que é só contexto' do
      Ai::Playbook.create!(department: department, steps: [
        { 'name' => 'CPF', 'objective' => 'Peça o CPF.', 'collect' => { 'attribute' => 'cpf' } },
        { 'name' => 'Endereço', 'objective' => 'Peça o endereço.' }
      ])
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        prompt = JSON.parse(req.body)['system_prompt']
        prompt.include?('NÃO pule pra ela, NÃO peça o dado dela') &&
          prompt.include?('se o cliente ADIANTAR um DADO dela por conta própria, capture normalmente')
      }
    end

    # Achado ao vivo: a IA recebeu o comprovante de residência (etapa N), viu que a PRÓXIMA etapa
    # (só contexto) instruía "chame a ferramenta de transferência... motivo conclusao_do_processo" e
    # executou essa ação AINDA na etapa N — o guardrail antigo só proibia pedir DADO da próxima etapa
    # cedo, nunca proibiu executar uma AÇÃO/ferramenta que ela descreve.
    it 'proíbe executar ação/ferramenta (ex.: transferir_humano) descrita na PRÓXIMA etapa antes da hora' do
      Ai::Playbook.create!(department: department, steps: [
        { 'name' => 'Comprovante', 'objective' => 'Peça o comprovante.', 'collect' => { 'attribute' => 'comprovante' } },
        { 'name' => 'Finalização', 'objective' => 'Confirmar e transferir.',
          'rules' => ["Chame a ferramenta de transferência para atendente com o motivo 'conclusao_do_processo'."] }
      ])
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        prompt = JSON.parse(req.body)['system_prompt']
        prompt.include?('NÃO execute nenhuma ação ou ferramenta que ela descreva') &&
          prompt.include?('mesmo que você já tenha todos os dados que a próxima etapa pediria')
      }
    end

    it 'não aparece na ÚLTIMA etapa (não há próxima)' do
      Ai::Playbook.create!(department: department, steps: [
        { 'name' => 'Única', 'objective' => 'Só isso.' }
      ])
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        !JSON.parse(req.body)['system_prompt'].include?('PRÓXIMA ETAPA')
      }
    end

    it 'não aparece sem playbook nenhum' do
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        !JSON.parse(req.body)['system_prompt'].include?('PRÓXIMA ETAPA')
      }
    end
  end

  # Ponto do usuário: o admin só escreve Objetivo/Regras em linguagem natural na tela da etapa —
  # "JSON"/"dados_coletados" nunca deveriam vir da BOCA do admin. Esta regra é montada pelo Rails a
  # partir do "Dado que esta etapa coleta" (o mesmo Select/collect.attribute), nomeando a chave exata
  # que a IA deve preencher em "dados_coletados" NESTA etapa — sem o admin nunca digitar isso.
  describe 'REGRA DE EXTRAÇÃO JSON (step_extraction_instruction — nomeia o collect.attribute da etapa ATUAL)' do
    it 'nomeia o attribute declarado no collect da etapa ativa' do
      Ai::Playbook.create!(department: department, steps: [
        { 'name' => 'Boas-vindas', 'instructions' => 'Cumprimente.' },
        { 'name' => 'CPF', 'instructions' => 'Peça o CPF.', 'collect' => { 'attribute' => 'cpf', 'type' => 'text' } }
      ])
      conversation.update!(additional_attributes: conversation.additional_attributes.merge('ai_step_index' => 1))
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        prompt = JSON.parse(req.body)['system_prompt']
        prompt.include?("REGRA DE EXTRAÇÃO JSON: Nesta etapa, você deve extrair o dado referente a 'cpf'") &&
          prompt.include?('adicionar um item na lista "dados_coletados"') &&
          prompt.include?('"chave": "cpf"')
      }
    end

    it 'não aparece numa etapa informativa (sem collect)' do
      Ai::Playbook.create!(department: department, steps: [
        { 'name' => 'Boas-vindas', 'instructions' => 'Cumprimente.' }
      ])
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        !JSON.parse(req.body)['system_prompt'].include?('REGRA DE EXTRAÇÃO JSON')
      }
    end

    it 'sem playbook nenhum, não aparece (current_step é nil)' do
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        !JSON.parse(req.body)['system_prompt'].include?('REGRA DE EXTRAÇÃO JSON')
      }
    end

    # Pedido do usuário (validação de formato): a IA só consegue validar CPF/telefone/escolha/etc.
    # contra o tipo/opções REAIS da etapa se esses dados chegarem no prompt — sem isso ela só tem o
    # nome do atributo. tools_schema tinha essa info (input_schema de "registrar_*"), mas essa tool é
    # filtrada antes de chegar à OpenAI no motor Python; step_slot_metadata_text é quem preenche a lacuna.
    it 'inclui tipo/opções/obrigatoriedade do slot (pro contexto de validação de formato)' do
      Ai::Playbook.create!(department: department, steps: [
        { 'name' => 'Plano', 'instructions' => 'Pergunte o plano.',
          'collect' => { 'attribute' => 'plano', 'type' => 'choice', 'options' => %w[Fibra 5G] } }
      ])
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        prompt = JSON.parse(req.body)['system_prompt']
        prompt.include?('tipo: choice') && prompt.include?('opções válidas: Fibra, 5G') && prompt.include?('OBRIGATÓRIO')
      }
    end

    it 'campo opcional (slot_required: false): metadata diz "opcional", não "OBRIGATÓRIO"' do
      Ai::Playbook.create!(department: department, steps: [
        { 'name' => 'Indicação', 'instructions' => 'Pergunte se tem indicação.', 'slot_required' => false,
          'collect' => { 'attribute' => 'indicacao', 'type' => 'text' } }
      ])
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        prompt = JSON.parse(req.body)['system_prompt']
        prompt.include?('tipo: text, opcional') && !prompt.include?('tipo: text, OBRIGATÓRIO')
      }
    end

    # Achado ao vivo (16/08, ticket 586): collect.attribute = ['cidade', 'viabilidade'] (2 atributos
    # numa etapa só) fazia o prompt nomear UMA chave colada '["cidade", "viabilidade"]' — a IA só tinha
    # instrução pra escrever essa chave colada, nunca as duas reais que a validação de avanço
    # (Api::Internal::AiExecuteToolController#collect_attributes) exigia separadas. A etapa nunca
    # completava: avancar_etapa vinha true, mas o índice nunca avançava, e o teto de "travado"
    # (stuck_handoff_turns) ia subindo turno a turno até estourar — sem nada de errado visível na
    # conversa. Agora o prompt nomeia as DUAS chaves reais, cada uma como item próprio.
    it 'etapa com MAIS de um atributo declarado: nomeia CADA atributo real, nunca uma chave colada' do
      Ai::Playbook.create!(department: department, steps: [
        { 'name' => 'Cidade', 'instructions' => 'Peça a cidade e verifique a viabilidade.',
          'collect' => { 'attribute' => %w[cidade viabilidade], 'options' => %w[Chapecó Maravilha] } }
      ])
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        prompt = JSON.parse(req.body)['system_prompt']
        prompt.include?("REGRA DE EXTRAÇÃO JSON: Nesta etapa, você deve extrair os dados referentes a 'cidade', 'viabilidade'") &&
          prompt.include?('CADA um vira um item PRÓPRIO em "dados_coletados", nunca uma') &&
          !prompt.include?('["cidade", "viabilidade"]')
      }
    end
  end

  # Pedido do usuário: apertar o foco (só o dado da etapa, exceto front-loading válido) + validar
  # formato por tipo antes de gravar + escalar (esclarecer 1x, depois transferir/aceitar vazio).
  describe 'REGRAS DE FOCO E VALIDAÇÃO DA COLETA (data_validation_instruction)' do
    it 'inclui foco na etapa atual, exceção de front-loading, valor-não-frase, e referência de formato por tipo' do
      Ai::Playbook.create!(department: department, steps: [
        { 'name' => 'CPF', 'instructions' => 'Peça o CPF.', 'collect' => { 'attribute' => 'cpf', 'type' => 'text' } }
      ])
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        prompt = JSON.parse(req.body)['system_prompt']
        prompt.include?('REGRAS DE FOCO E VALIDAÇÃO DA COLETA') &&
          prompt.include?('Extraia para "dados_coletados" APENAS o dado que a etapa atual está pedindo explicitamente') &&
          prompt.include?('EXCEÇÃO: se o cliente adiantar espontaneamente um dado de uma etapa FUTURA') &&
          prompt.include?('Grave sempre o VALOR extraído, nunca a frase inteira do cliente') &&
          prompt.include?('CPF = 11 dígitos numéricos') &&
          prompt.include?('telefone = mínimo 8 dígitos numéricos') &&
          prompt.include?('e-mail = contém @ e domínio válido')
      }
    end

    it 'etapa com MAIS de um atributo: foco cita os dois, no plural' do
      Ai::Playbook.create!(department: department, steps: [
        { 'name' => 'Cidade', 'instructions' => 'Peça a cidade.',
          'collect' => { 'attribute' => %w[cidade viabilidade] } }
      ])
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        prompt = JSON.parse(req.body)['system_prompt']
        prompt.include?('Extraia para "dados_coletados" APENAS os dados que a etapa atual está pedindo ' \
                         'explicitamente ("cidade" e "viabilidade"')
      }
    end

    # Achado ao vivo (17/08): a versão anterior desta regra mandava a IA marcar "transferir_humano": true
    # depois de só 1 tentativa fracassada — um limiar PRÓPRIO que contradizia o teto configurável na tela
    # de Etapas (stuck_handoff_turns). Removido: "quantas tentativas antes de desistir" agora é
    # EXCLUSIVAMENTE do backend (Ai::Gateway#step_turns_exceeded?); o texto só instrui a IA a continuar
    # pedindo com paciência, sem se auto-transferir pela contagem.
    it 'campo opcional aceita vazio e avança; campo obrigatório NÃO se auto-transfere pela contagem' do
      Ai::Playbook.create!(department: department, steps: [
        { 'name' => 'CPF', 'instructions' => 'Peça o CPF.', 'collect' => { 'attribute' => 'cpf', 'type' => 'text' } }
      ])
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        prompt = JSON.parse(req.body)['system_prompt']
        prompt.include?('NÃO marque "transferir_humano" só pela quantidade de tentativas') &&
          prompt.include?('mande "dados_coletados" vazio ([]) e defina "avancar_etapa": true') &&
          !prompt.include?('campo OBRIGATÓRIO → defina "transferir_humano": true')
      }
    end

    it 'não aparece numa etapa informativa (sem collect) — nada pra validar' do
      Ai::Playbook.create!(department: department, steps: [
        { 'name' => 'Boas-vindas', 'instructions' => 'Cumprimente.' }
      ])
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        !JSON.parse(req.body)['system_prompt'].include?('REGRAS DE FOCO E VALIDAÇÃO DA COLETA')
      }
    end
  end

  # Bug URGENTE ao vivo: etapas escritas (ou geradas pelo Ai::PromptAssistant) ANTES da migração pra
  # Structured Outputs têm texto tipo "chame a ferramenta registrar_X"/"chame a ferramenta
  # avancar_etapa" salvo no banco — tools que orchestrator.py não oferece mais à OpenAI. A IA lia,
  # procurava a tool, não achava, e desistia (encerrava o atendimento). #current_step_instructions
  # reescreve essas referências pelo equivalente no contrato JSON, SEM apagar o resto da frase.
  describe 'sanitização de texto de etapa com tool-calling obsoleto (bug do encerramento prematuro)' do
    it 'reescreve "chame a ferramenta registrar_X" preservando o critério ao redor' do
      Ai::Playbook.create!(department: department, steps: [
        { 'name' => 'Nome', 'objective' => 'Coletar o nome.',
          'rules' => ['Assim que o cliente informar o nome, chame a ferramenta registrar_nome_cliente.'],
          'collect' => { 'attribute' => 'nome_cliente' } }
      ])
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        prompt = JSON.parse(req.body)['system_prompt']
        prompt.include?('Assim que o cliente informar o nome, inclua esse dado em "dados_coletados" no seu JSON de resposta.') &&
          !prompt.include?('chame a ferramenta registrar_nome_cliente') &&
          !prompt.include?('registrar_nome_cliente')
      }
    end

    it 'reescreve "chame a ferramenta avancar_etapa" preservando o critério ao redor' do
      Ai::Playbook.create!(department: department, steps: [
        { 'name' => 'Nome', 'objective' => 'Coletar o nome.',
          'rules' => ['Assim que tiver capturado o nome, chame a ferramenta avancar_etapa.'] }
      ])
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        prompt = JSON.parse(req.body)['system_prompt']
        prompt.include?('Assim que tiver capturado o nome, defina "avancar_etapa": true no seu JSON de resposta.') &&
          !prompt.include?('chame a ferramenta avancar_etapa')
      }
    end

    it 'NÃO mexe em referência a uma tool REAL (admin-configurada) na etapa' do
      Ai::Tool.create!(account: account, ai_department_id: department.id, name: 'consultar_periodos',
                       implementation_type: 'capability', capability_key: 'x.y', status: 'active', description: 'x')
      Ai::Playbook.create!(department: department, steps: [
        { 'name' => 'Períodos', 'objective' => 'Informar períodos disponíveis.',
          'rules' => ['Antes de responder, chame a ferramenta consultar_periodos.'] }
      ])
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        JSON.parse(req.body)['system_prompt'].include?('chame a ferramenta consultar_periodos')
      }
    end
  end

  describe 'system_prompt traz encerramento/transferência configurados + instrução do contrato JSON' do
    it 'inclui transfer_when/close_when (do playbook) e a mensagem de encerramento (do department)' do
      Ai::Playbook.create!(department: department, transfer_when: ['cliente pede humano'],
                           close_when: ['cliente confirma que não quer mais nada'])
      department.update!(close_rules: { 'message' => 'Foi um prazer te atender!' })
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        prompt = JSON.parse(req.body)['system_prompt']
        # Structured Outputs (orchestrator.py): a IA não chama mais "conversation.resolve"/
        # "conversation.transfer" por nome — expressa a mesma decisão via "transferir_humano"/
        # "encerrar_atendimento" no JSON, que o Python lê e é quem chama o webhook.
        prompt.include?('Transfira para humano quando: cliente pede humano.') &&
          prompt.include?('Encerre quando: cliente confirma que não quer mais nada.') &&
          prompt.include?('Foi um prazer te atender!') &&
          prompt.include?('"transferir_humano": true ou false') &&
          prompt.include?('"encerrar_atendimento": true ou false')
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

  describe 'imagem do WhatsApp e documentos escaneados (image_urls no payload)' do
    it 'inclui a URL real do anexo de imagem da mensagem, quando passada' do
      message = create(:message, conversation: conversation, account: account)
      attachment = message.attachments.create!(account: account, file_type: :image)
      allow(attachment).to receive(:download_url).and_return('https://cdn.example.com/foto.jpg')
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department,
                                      mode: 'live', message: message)

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL)
        .with(body: hash_including('image_urls' => ['https://cdn.example.com/foto.jpg']))
    end

    it 'image_urls vem [] quando não há mensagem/anexo de imagem nem documento escaneado' do
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL)
        .with(body: hash_including('image_urls' => []))
    end

    # Achado ao vivo: PDF escaneado (CNH) lido por uma chamada de visão SEPARADA (Ai::Workers::
    # MediaProcessor), sem contexto da etapa, alucinava dado (1997 virou 1991). Agora as páginas
    # rasterizadas entram em image_urls — o MESMO turno principal (com o contexto da etapa e a regra
    # de "não chutar", ver #document_extraction_instruction) lê o documento, não uma chamada à parte.
    it 'inclui as páginas rasterizadas de um PDF escaneado (via MediaProcessor.pending_vision_images)' do
      message = create(:message, conversation: conversation, account: account)
      allow(Ai::Workers::MediaProcessor).to receive(:pending_vision_images).with(message)
                                                                            .and_return(['data:image/png;base64,AAAA'])
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department,
                                      mode: 'live', message: message)

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL)
        .with(body: hash_including('image_urls' => ['data:image/png;base64,AAAA']))
    end

    it 'foto direta E páginas de documento no mesmo turno: foto primeiro, depois as páginas' do
      message = create(:message, conversation: conversation, account: account)
      attachment = message.attachments.create!(account: account, file_type: :image)
      allow(attachment).to receive(:download_url).and_return('https://cdn.example.com/foto.jpg')
      allow(Ai::Workers::MediaProcessor).to receive(:pending_vision_images).with(message)
                                                                            .and_return(['data:image/png;base64,BBBB'])
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department,
                                      mode: 'live', message: message)

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL)
        .with(body: hash_including('image_urls' => ['https://cdn.example.com/foto.jpg', 'data:image/png;base64,BBBB']))
    end
  end

  # Fecha a lacuna de identidade (IA sugerindo concorrentes) + a base de conhecimento real deste
  # path (Ai::KnowledgeRetriever — pgvector já populado, NÃO o vector_store nativo da OpenAI, que
  # não existe: vector_store_id sempre vem vazio, auditado, sem tela/job que o preencha).
  describe 'identidade + conhecimento no system_prompt' do
    it 'com conhecimento cadastrado: identidade é a PRIMEIRA linha, identify_as a SEGUNDA, o guardrail anti-"médias de mercado" a TERCEIRA — as duas primeiras referenciam a ferramenta' do
      add_knowledge!
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        prompt_lines = JSON.parse(req.body)['system_prompt'].lines
        prompt_lines.first.include?('IDENTIDADE') &&
          prompt_lines.first.include?('É ESTRITAMENTE PROIBIDO sugerir que o cliente procure outras') &&
          prompt_lines.first.include?('use a ferramenta "consultar_conhecimento"') &&
          prompt_lines[2].include?('Nunca cite concorrentes, médias de mercado') &&
          prompt_lines[2].include?('ferramenta "consultar_conhecimento"')
      }
    end

    # Consequência direta de tornar #knowledge_tool condicional: sem NENHUM Ai::KnowledgeSource
    # cadastrado, a ferramenta não está em tools_schema — citar o nome dela aqui instruiria a IA a
    # chamar algo que não existe, então a frase se adapta (ver #identity_instruction/
    # #market_average_guardrail).
    it 'sem conhecimento cadastrado: identidade/guardrail não citam a ferramenta ausente' do
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        prompt_lines = JSON.parse(req.body)['system_prompt'].lines
        prompt_lines.first.include?('IDENTIDADE') &&
          prompt_lines.first.include?('É ESTRITAMENTE PROIBIDO sugerir que o cliente procure outras') &&
          !prompt_lines.first.include?('consultar_conhecimento') &&
          prompt_lines[2].include?('Nunca cite concorrentes, médias de mercado') &&
          !prompt_lines[2].include?('consultar_conhecimento')
      }
    end

    # Regressão achada ao vivo 13/08 (Maya v5.0, identify_as='human'): esta instrução existia no
    # Ai::PromptCompiler legado (identity_lines) e nunca foi portada pro Python — o split em várias
    # mensagens (Ai::ActionDispatcher#split_parts) continuava funcionando no código, mas o modelo
    # nunca era instruído a produzir "\n\n" em mensagem_para_cliente, então não tinha o que quebrar.
    describe 'identify_as_instruction (segunda linha do system_prompt)' do
      it 'identify_as="human" (default do agent): instrui a quebrar em mensagens curtas com linha em branco' do
        agent.update!(identify_as: 'human')
        stub_orchestrator

        described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

        expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
          line = JSON.parse(req.body)['system_prompt'].lines[1]
          line.include?('Aja como um atendente humano da equipe') &&
            line.include?('Não diga que é uma inteligência artificial') &&
            line.include?('LINHA EM BRANCO entre elas (dois \n)') &&
            line.include?('"mensagem_para_cliente"')
        }
      end

      it 'identify_as="ai": NÃO instrui a quebrar em várias mensagens, pode se assumir IA' do
        agent.update!(identify_as: 'ai')
        stub_orchestrator

        described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

        expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
          line = JSON.parse(req.body)['system_prompt'].lines[1]
          line.include?('assistente virtual (IA)') && !line.include?('LINHA EM BRANCO')
        }
      end
    end

    # RAG agentic: nenhuma busca automática por turno mais — Ai::KnowledgeRetriever só roda quando a
    # PRÓPRIA IA chama a tool consultar_conhecimento (ver ai_execute_tool_controller_spec.rb), nunca
    # embutido cego no system_prompt a partir da mensagem crua do cliente (era o bloco antigo).
    it 'NÃO chama Ai::KnowledgeRetriever ao montar o system_prompt (a busca só acontece via tool call)' do
      allow(Ai::KnowledgeRetriever).to receive(:retrieve)
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'quanto custa o plano fibra?',
                                      agent: agent, department: department, mode: 'live')

      expect(Ai::KnowledgeRetriever).not_to have_received(:retrieve)
    end

    it 'NÃO injeta mais o bloco fixo "## CONHECIMENTO OFICIAL DA EMPRESA" — a IA busca via tool' do
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'quanto custa o plano fibra?',
                                      agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        !JSON.parse(req.body)['system_prompt'].include?('## CONHECIMENTO OFICIAL DA EMPRESA')
      }
    end

    it 'a tool "consultar_conhecimento" entra em tools_schema quando o department TEM conhecimento cadastrado, com "pergunta" obrigatória' do
      add_knowledge!
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        tool = JSON.parse(req.body)['tools_schema'].find { |t| t['name'] == 'consultar_conhecimento' }
        # Descrição genérica: nenhum termo amarrado a um segmento específico (ex.: "fibra"/"internet"/
        # "plano de dados") — qualquer negócio usa a mesma tool com o mesmo texto.
        tool.present? &&
          tool['input_schema']['required'] == ['pergunta'] &&
          tool['input_schema']['properties']['pergunta']['type'] == 'string' &&
          !tool['description'].downcase.include?('fibra') &&
          !tool['description'].downcase.include?('internet')
      }
    end

    # Pedido do usuário: sem NENHUM conhecimento cadastrado pro department, a tool nem entra no array
    # — oferecer uma ferramenta que sempre volta vazia só ensina a IA a gastar uma rodada de tool-call
    # à toa. Mesma conta/department de todos os outros testes deste arquivo (nenhum cadastra
    # Ai::KnowledgeSource por padrão), então este teste também documenta o comportamento default.
    it 'a tool "consultar_conhecimento" NÃO entra em tools_schema sem nenhum conhecimento cadastrado' do
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        JSON.parse(req.body)['tools_schema'].none? { |t| t['name'] == 'consultar_conhecimento' }
      }
    end

    # Uma fonte cadastrada mas ainda sem chunk indexado (ingest ainda não rodou, ou raw vazio) conta
    # como "sem conhecimento" — a ferramenta só ajuda quando há o que buscar de verdade.
    it 'a tool "consultar_conhecimento" NÃO entra em tools_schema quando a fonte existe mas ainda não tem chunk indexado' do
      allow(Ai::KnowledgeIngestJob).to receive(:perform_later)
      Ai::KnowledgeSource.create!(account: account, ai_department_id: department.id, kind: 'faq', title: 'FAQ')
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        JSON.parse(req.body)['tools_schema'].none? { |t| t['name'] == 'consultar_conhecimento' }
      }
    end

    # Conhecimento COMPARTILHADO da conta (ai_department_id nil) também conta — mesmo escopo que
    # Ai::KnowledgeRetriever#source_ids_for usa pra buscar de verdade.
    it 'a tool "consultar_conhecimento" entra em tools_schema quando o conhecimento é compartilhado da conta (sem department específico)' do
      allow(Ai::KnowledgeIngestJob).to receive(:perform_later)
      source = Ai::KnowledgeSource.create!(account: account, kind: 'faq', title: 'FAQ geral')
      Ai::KnowledgeChunk.create!(ai_knowledge_source_id: source.id, content: 'Horário de atendimento: 9h às 18h.', embedding: nil)
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        JSON.parse(req.body)['tools_schema'].any? { |t| t['name'] == 'consultar_conhecimento' }
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

  # Bug real ao vivo: Rails gravava certinho em ai_collected_facts (via registrar_*/salvar_memoria_ia),
  # mas o system_prompt nunca injetava esse resumo de volta — a IA "esquecia" o que o próprio cliente
  # já tinha informado e reperguntava. Espelha o "Dados já coletados" do caminho legado.
  describe 'DADOS JÁ COLETADOS (ai_collected_facts injetado no system_prompt)' do
    def with_facts(facts)
      conversation.update!(additional_attributes: conversation.additional_attributes.merge('ai_collected_facts' => facts))
    end

    it 'injeta cada chave/valor de ai_collected_facts, ANTES do bloco ETAPA ATUAL' do
      with_facts('nome' => 'Maria', 'cidade' => 'Chapecó')
      Ai::Playbook.create!(department: department, steps: [{ 'name' => 'Boas-vindas', 'objective' => 'Cumprimentar.' }])
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        prompt = JSON.parse(req.body)['system_prompt']
        facts_idx = prompt.index('DADOS JÁ COLETADOS NESTA CONVERSA')
        etapa_idx = prompt.index('ETAPA ATUAL')
        prompt.include?('- nome: Maria') &&
          prompt.include?('- cidade: Chapecó') &&
          prompt.include?('Não pergunte nada disso de novo, já está salvo no sistema') &&
          facts_idx.present? && etapa_idx.present? && facts_idx < etapa_idx
      }
    end

    it 'ai_collected_facts VAZIO ({}): o bloco não aparece' do
      with_facts({})
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        !JSON.parse(req.body)['system_prompt'].include?('DADOS JÁ COLETADOS')
      }
    end

    it 'sem ai_collected_facts (conversa nova): o bloco não aparece' do
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        !JSON.parse(req.body)['system_prompt'].include?('DADOS JÁ COLETADOS')
      }
    end

    # Gap 1 do caminho legado: Ai::StepSlot::ABSENT ('__sem_valor__') é um TOKEN interno — nunca pode
    # vazar cru pro modelo (motivo: pode ter sido gravado pelo motor legado nesta MESMA conversa, se o
    # department alternou o flag python_orchestrator no meio do atendimento).
    it 'valor ABSENT (recusa do motor legado) aparece como "não informado", NUNCA o token cru' do
      with_facts('cpf' => Ai::StepSlot::ABSENT)
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        prompt = JSON.parse(req.body)['system_prompt']
        prompt.include?('- cpf: não informado') && !prompt.include?('__sem_valor__')
      }
    end
  end

  # Achado ao vivo: a IA leu uma CNH (PDF) e alucinou o ano (1997 virou 1991) + salvou dado que a
  # etapa nem pediu (nascimento, RG). Ler o documento é DESEJADO (não proibir) — o problema era
  # confiar cegamente numa leitura incerta E extrair mais do que foi pedido.
  describe 'REGRA DE EXTRAÇÃO DE DOCUMENTOS (document_extraction_instruction)' do
    it 'instrui a IA a extrair o que a etapa pede, sem chutar quando não tiver certeza visual' do
      message = create(:message, conversation: conversation, account: account)
      attachment = message.attachments.create!(account: account, file_type: :image)
      allow(attachment).to receive(:download_url).and_return('https://cdn.example.com/foto.jpg')
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department,
                                      mode: 'live', message: message)

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        prompt = JSON.parse(req.body)['system_prompt']
        prompt.include?('REGRA DE EXTRAÇÃO DE DOCUMENTOS') &&
          prompt.include?('analise a imagem cuidadosamente para extrair os dados solicitados pela etapa atual') &&
          prompt.include?('NÃO chute') &&
          prompt.include?('Não consegui ler o [dado] com clareza na foto') &&
          prompt.include?('extraia SÓ o que a etapa atual está pedindo, mesmo que o documento mostre outros campos')
      }
    end

    it 'NÃO proíbe a leitura de documentos — o usuário foi explícito que a IA DEVE ler' do
      message = create(:message, conversation: conversation, account: account)
      attachment = message.attachments.create!(account: account, file_type: :image)
      allow(attachment).to receive(:download_url).and_return('https://cdn.example.com/foto.jpg')
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department,
                                      mode: 'live', message: message)

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        prompt = JSON.parse(req.body)['system_prompt']
        !prompt.include?('PROIBIDO extrair dados de imagens ou PDFs')
      }
    end

    # Achado 14/08: o bloco (5 linhas) ia pro system_prompt em TODO turno, mesmo nos que são só texto
    # puro — a maioria. Gate por #image_urls.present? (mesmo cálculo que já decide o payload).
    it 'OMITE o bloco em turno de texto puro, sem anexo/imagem/documento' do
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        prompt = JSON.parse(req.body)['system_prompt']
        !prompt.include?('REGRA DE EXTRAÇÃO DE DOCUMENTOS')
      }
    end
  end

  # Mesma classe de bug do "fake-save" (dizer que salvou sem preencher dados_coletados) — só que pros
  # campos transferir_humano/encerrar_atendimento: nada impedia o modelo de escrever "vou te
  # transferir"/"atendimento encerrado" em mensagem_para_cliente sem marcar o booleano correspondente.
  # O cliente recebia a promessa; a ação (handoff real / resolver a conversa) nunca acontecia.
  describe 'PROIBIÇÃO de "fake-transfer"/"fake-close" (dizer sem marcar o campo)' do
    it 'proíbe alegar transferência sem marcar transferir_humano+handoff_summary' do
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        prompt = JSON.parse(req.body)['system_prompt']
        prompt.include?('É ESTRITAMENTE PROIBIDO escrever em "mensagem_para_cliente" qualquer variação de "vou transferir"') &&
          prompt.include?('marcar "transferir_humano": true e preencher "handoff_summary"') &&
          prompt.include?('a transferência NÃO acontece e o cliente fica sem atendimento')
      }
    end

    it 'proíbe alegar encerramento sem marcar encerrar_atendimento' do
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        prompt = JSON.parse(req.body)['system_prompt']
        prompt.include?('É ESTRITAMENTE PROIBIDO escrever em "mensagem_para_cliente" qualquer variação de "atendimento encerrado"') &&
          prompt.include?('sem marcar "encerrar_atendimento": true na MESMA resposta')
      }
    end
  end

  # 4 falhas de comportamento achadas em teste ao vivo: IA "fingindo" ter salvo um dado sem salvar de
  # verdade, inventando situações/recursos que não existem, transferindo sem motivo (pulando o fluxo
  # de etapas), e empilhando várias perguntas de etapas diferentes na mesma mensagem. As duas primeiras
  # agora são cobertas pelo contrato Structured Outputs (#structured_output_instruction) em vez de
  # instruções de function-calling — ver describe abaixo.
  describe 'guardrails de comportamento (achados em teste ao vivo)' do
    it 'inclui as 4 instruções — contrato JSON estruturado, não inventar, disciplina de transferência, uma pergunta por vez' do
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        prompt = JSON.parse(req.body)['system_prompt']
        prompt.include?('FORMATO DE RESPOSTA OBRIGATÓRIO') &&
          prompt.include?('É PROIBIDO inventar situações, recursos ou funcionalidades que não existem') &&
          prompt.include?('Transfira para humano quando') &&
          prompt.include?('Prefira pedir os dados da etapa atual UM DE CADA VEZ')
      }
    end

    # Generalização do fix de consultar_conhecimento (knowledge_timeout/knowledge_search_failed) pra
    # QUALQUER ferramenta real: achado ao vivo (conv 556, consultar_periodos) — falha real de
    # ferramenta não tinha instrução nenhuma, a IA travava enrolando o cliente em vez de avisar ou
    # transferir. orchestrator.py normaliza toda falha real em {"error": true, "message": "..."}.
    it 'instrui a reagir a "error": true de qualquer ferramenta avisando problema técnico e oferecendo transferir' do
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        prompt = JSON.parse(req.body)['system_prompt']
        prompt.include?('"error": true') &&
          prompt.include?('falha TÉCNICA real da ferramenta') &&
          prompt.include?('avise o cliente que teve um problema técnico') &&
          prompt.include?('ofereça transferir para um atendente humano') &&
          prompt.include?('NUNCA chame a mesma ferramenta de novo no mesmo turno')
      }
    end

    # Achado ao vivo (17/08): "não exija mais de 1 nova tentativa por dado antes de transferir" era um
    # limiar POR CONTAGEM que a IA aplicava sozinha — contradizia o teto configurável na tela de Etapas
    # (stuck_handoff_turns): se o admin configura X mensagens de tolerância, a IA não pode desistir bem
    # antes disso por conta própria. Removido — só os gatilhos por CONTEÚDO (pedido explícito,
    # frustração) continuam levando a transferência IMEDIATA; contagem de tentativas é só do backend.
    it 'transfere imediato por pedido/frustração, mas NÃO se auto-transfere por contagem de tentativas' do
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        prompt = JSON.parse(req.body)['system_prompt']
        prompt.include?('demonstrar frustração clara') &&
          prompt.include?('transfira IMEDIATAMENTE, mesmo sem ter tentado esclarecer antes') &&
          prompt.include?('NÃO transfira só pela QUANTIDADE de tentativas') &&
          !prompt.include?('não exija mais de 1 nova tentativa por dado antes de transferir') &&
          !prompt.include?('5 mensagens')
      }
    end

    # Tom (cadência "uma pergunta por vez") não deve competir com fato (captura de dado front-loaded) —
    # a regra agora tem exceção explícita em vez de proibição absoluta.
    it 'a instrução de cadência tem exceção explícita pra dado front-loaded pelo cliente' do
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        prompt = JSON.parse(req.body)['system_prompt']
        prompt.include?('EXCEÇÃO: se o cliente fornecer espontaneamente mais de um dado na mesma mensagem') &&
          prompt.include?('registre TODOS os dados válidos fornecidos naquela mensagem') &&
          prompt.include?('nunca finja que não viu um dado só para manter o ritmo')
      }
    end

    # Bug real ao vivo, round 2 (era do design de tool-calling): a IA chamava "continuar_conversa" (o
    # no-op que sustentava tool_choice="required") e dizia em texto "Recebi seu CPF!" sem NUNCA chamar
    # registrar_*/salvar_memoria_ia — nada persistia, a etapa seguinte repetia a pergunta (loop de
    # dados). Sob Structured Outputs isso deixou de ser possível por construção: não há mais tool
    # nenhuma pra "fingir" chamar, só o campo "dados_coletados" do JSON — guarda contra REMOVER a
    # regra que proíbe alegar salvamento sem preencher esse campo.
    it 'proíbe alegar que salvou sem preencher "dados_coletados", e diz que o dado se perde se isso acontecer' do
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'meu cpf é 123', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        prompt = JSON.parse(req.body)['system_prompt']
        prompt.include?('É ESTRITAMENTE PROIBIDO dizer em "mensagem_para_cliente" que recebeu/anotou um dado') &&
          prompt.include?('colocar esse dado em "dados_coletados"') &&
          prompt.include?('o dado será PERDIDO')
      }
    end

    # A descrição da PRÓPRIA tool "continuar_conversa" (Ai::PythonOrchestratorClient#control_tools)
    # ainda existe em tools_schema — legado inofensivo, filtrado no lado Python antes de chegar à
    # OpenAI (orchestrator.py, tool_choice="required" não existe mais) — mas o texto de aviso segue
    # correto caso algum department antigo ainda leia esse catálogo por outro caminho.
    it 'a descrição da tool continuar_conversa (tools_schema) avisa explicitamente pra não usar quando há dado novo' do
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        tool = JSON.parse(req.body)['tools_schema'].find { |t| t['name'] == 'continuar_conversa' }
        tool.present? &&
          tool['description'].include?('NUNCA use esta ferramenta se o cliente ACABOU de fornecer um dado') &&
          tool['description'].include?('PERDE o dado do cliente')
      }
    end

    # Bug real ao vivo (WhatsApp), 2 rodadas: cliente disse "vendas", a IA respondeu "Perfeito, é
    # vendas mesmo?" em loop, sem nunca registrar/avançar. A instrução original (function-calling) foi
    # substituída pela regra equivalente do contrato JSON: registrar em "dados_coletados" e marcar
    # "avancar_etapa": true na MESMA resposta, sem turno extra de confirmação.
    it 'proíbe pedir confirmação e manda registrar + avançar na mesma resposta, sem turno extra' do
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'vendas', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        prompt = JSON.parse(req.body)['system_prompt']
        prompt.include?("NÃO peça confirmação ('é isso mesmo?', 'posso confirmar?')") &&
          prompt.include?('registre o dado em "dados_coletados" E marque "avancar_etapa": true na') &&
          prompt.include?('sem inserir um turno extra de confirmação')
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
        JSON.parse(req.body)['system_prompt'].include?('preencha "handoff_summary" com o que já foi conseguido')
      }
    end
  end

  # Achado ao vivo (17/08): o motor Ruby legado deixava a IA nomear o TIME de destino do handoff
  # (handoff_target, casado contra a whitelist agent.handoff_team_ids — Ai::PromptCompiler
  # #human_handoff_teams) — o Structured Outputs nunca reproduziu isso, então toda transferência direta
  # caía sempre no mesmo time default, cega à intenção. Reusa a MESMA função pura do motor legado.
  describe 'Times disponíveis (handoff_target_instruction)' do
    it 'lista os times da whitelist do agente e instrui a copiar o nome EXATO' do
      team_a = create(:team, account: account, name: 'Suporte Técnico')
      team_b = create(:team, account: account, name: 'Financeiro')
      agent.update!(handoff_team_ids: [team_a.id, team_b.id])
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        prompt = JSON.parse(req.body)['system_prompt']
        prompt.include?('preencha "handoff_target" com o nome') &&
          prompt.include?('- Suporte Técnico') &&
          prompt.include?('- Financeiro')
      }
    end

    it 'sem NENHUM time na conta, não aparece (nada pra IA escolher)' do
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        !JSON.parse(req.body)['system_prompt'].include?('handoff_target')
      }
    end
  end

  # Achado ao vivo (17/08): Ai::StateManager#mirror_contact_facts já grava em Ai::CustomerMemory a cada
  # turno (cross-conversa/cross-agente), mas nada no caminho Python lia essa memória de volta — o motor
  # Ruby legado tinha isso (Ai::PromptCompiler#customer_memory_lines). Write-only até este fix.
  describe 'MEMÓRIA DESTE CLIENTE (customer_memory_block)' do
    it 'apresenta resumo e dados lembrados de atendimentos ANTERIORES deste contato' do
      Ai::CustomerMemory.create!(account: account, contact_id: conversation.contact_id,
                                 summary: 'Cliente recorrente, já é assinante do Plano 450.',
                                 key_facts: { 'cidade' => 'Maravilha', 'documento_cpf' => '11033636975' })
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        prompt = JSON.parse(req.body)['system_prompt']
        prompt.include?('MEMÓRIA DESTE CLIENTE (de atendimentos ANTERIORES, não desta conversa') &&
          prompt.include?('Cliente recorrente, já é assinante do Plano 450.') &&
          prompt.include?('- cidade: Maravilha') &&
          prompt.include?('- documento_cpf: 11033636975')
      }
    end

    it 'sem NENHUM registro de memória pra este contato, não aparece' do
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        !JSON.parse(req.body)['system_prompt'].include?('MEMÓRIA DESTE CLIENTE')
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

    # Structured Outputs: a IA não escolhe mais entre "registrar_*" e "salvar_memoria_ia" — todo dado
    # (com ou sem tool dedicada no design antigo) vai pro mesmo lugar, "dados_coletados"; é o Python
    # (orchestrator.py#_dispatch_structured_reply) quem sempre chama o webhook salvar_memoria_ia por
    # baixo, pra CADA item da lista, sem a IA precisar saber que essa tool existe.
    it 'system_prompt instrui a IA a colocar QUALQUER dado em "dados_coletados", sem tool dedicada' do
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        JSON.parse(req.body)['system_prompt'].include?('adicione UM ITEM em "dados_coletados"')
      }
    end
  end

  # Histórico: era o escape-valve pra tool_choice="required" (bug antigo — a IA respondia só com texto
  # e nunca chamava nenhuma tool). orchestrator.py não força mais tool_choice nenhum (Structured
  # Outputs substituiu essa mecânica inteira): "continuar_conversa" continua sendo GERADA aqui
  # (Ai::PythonOrchestratorClient#control_tools) por ora, mas orchestrator.py a filtra antes de montar
  # a lista de tools da OpenAI — leftover inofensivo, não usado pelo contrato JSON novo. O
  # system_prompt não fala mais dela (ver #structured_output_instruction).
  describe 'tool "continuar_conversa" (legado — filtrada no lado Python, nunca chega à OpenAI)' do
    it 'ainda presente em tools_schema, sem parâmetros' do
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, department: department, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        tool = JSON.parse(req.body)['tools_schema'].find { |t| t['name'] == 'continuar_conversa' }
        tool.present? && tool['input_schema'] == { 'type' => 'object', 'properties' => {} }
      }
    end
  end
end
