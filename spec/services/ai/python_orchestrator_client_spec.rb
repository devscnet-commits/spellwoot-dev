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
  before do
    conversation.update!(additional_attributes: { 'openai_conversation_id' => 'conv_previous_123' })
  end

  def stub_orchestrator(status: 200, body: { reply: 'Olá! Como posso ajudar?', conversation_id: 'conv_novo_456' })
    stub_request(:post, described_class::ORCHESTRATOR_URL)
      .to_return(status: status, body: body.to_json, headers: { 'Content-Type' => 'application/json' })
  end

  # Cadastra conhecimento pro agente (fonte + chunk já indexado) — mesmo shape de
  # spec/services/ai/knowledge_retriever_spec.rb. Sem isto, NENHUM teste deste arquivo tem
  # #has_knowledge? true (o agente de teste não nasce com nenhum Ai::KnowledgeSource).
  def add_knowledge!(content: 'Atendemos de segunda a sexta, das 9h às 18h.')
    allow(Ai::KnowledgeIngestJob).to receive(:perform_later)
    source = Ai::KnowledgeSource.create!(account: account, ai_agent_id: agent.id, kind: 'faq', title: 'FAQ')
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
        conversation: conversation, content: 'Quero saber o preço', agent: agent, mode: 'live'
      )

      expect(result).to eq(reply: 'Olá! Como posso ajudar?', conversation_id: 'conv_novo_456', byok_fallback: false)
      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL)
        .with(body: hash_including(
          'ticket_id' => conversation.id,
          'ai_agent_id' => agent.id,
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
        conversation: conversation, content: 'oi', agent: agent, mode: 'live'
      )

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL)
        .with(body: hash_including('model' => nil, 'provider' => nil, 'temperature' => nil))
    end

    it 'nunca sobe uma exceção quando o orquestrador responde com erro — devolve reply em branco' do
      stub_orchestrator(status: 500, body: { error: 'boom' })

      result = described_class.process_message(
        conversation: conversation, content: 'oi', agent: agent, mode: 'live'
      )

      expect(result).to eq(reply: nil, conversation_id: nil, byok_fallback: false, confidence: nil, transferred: false)
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
        conversation: conversation, content: 'oi', agent: agent, mode: 'live'
      )

      expect(result).to eq(reply: nil, conversation_id: nil, byok_fallback: false, confidence: nil, transferred: false)
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

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL)
        .with(body: hash_including('account_api_key' => 'sk-conta-propria'))
    end

    it 'manda account_api_key nil quando a conta NÃO tem a feature ligada (comportamento de sempre)' do
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL)
        .with(body: hash_including('account_api_key' => nil))
    end

    it 'devolve byok_fallback: true quando o Python avisa que a chave própria falhou e caiu pra global' do
      stub_orchestrator(body: { reply: 'oi', conversation_id: 'conv_1', byok_fallback: true })

      result = described_class.process_message(conversation: conversation, content: 'oi', agent: agent, mode: 'live')

      expect(result[:byok_fallback]).to be true
    end

    it 'devolve byok_fallback: false quando o Python não manda o campo (retrocompat)' do
      stub_orchestrator(body: { reply: 'oi', conversation_id: 'conv_1' })

      result = described_class.process_message(conversation: conversation, content: 'oi', agent: agent, mode: 'live')

      expect(result[:byok_fallback]).to be false
    end
  end

  # Achado 14/08 (ticket 563, Frente 1): a análise de compactação de prompt usou o playbook real do
  # Agente 5 (Maya v5.0, provedor de internet — etapas "VIABILIDADE", "PLANOS", atributos
  # "cidade"/"documento_cpf"/etc.) como CASO DE TESTE, não como molde — o sistema é multi-cliente
  # configurável. Este teste prova que o renderizador (Ai::StepInstructionText +
  # #step_extraction_instruction/#data_validation_instruction/#current_step_instructions/
  # #next_step_instructions) é 100% genérico: um playbook de domínio TOTALMENTE alheio (pedido de
  # pizza — zero overlap de vocabulário com a Maya) produz a MESMA estrutura de blocos, sem nenhum
  # hardcode de nome de etapa ou atributo escondido no meio do caminho.
  describe 'renderização de etapa é 100% genérica (achado 14/08, validação da Frente 1)' do
    it 'produz a mesma estrutura de blocos pra um playbook de domínio completamente diferente do da Maya' do
      Ai::Playbook.create!(agent: agent, steps: [
        { 'name' => 'sabor', 'objective' => 'Descobrir o sabor da pizza que o cliente quer.',
          'rules' => ['Se o cliente pedir "surpresa", sugira o sabor mais vendido do dia.'],
          'collect' => { 'attribute' => 'sabor_pizza', 'type' => 'text' } },
        { 'name' => 'entrega', 'objective' => 'Confirmar o endereço de entrega.',
          'collect' => { 'attribute' => 'endereco_entrega', 'type' => 'text' } }
      ])
      conversation.update!(additional_attributes: conversation.additional_attributes.merge('ai_step_index' => 0))

      captured = []
      stub_request(:post, described_class::ORCHESTRATOR_URL).to_return do |request|
        captured << JSON.parse(request.body)
        { status: 200, body: { reply: 'ok', conversation_id: 'conv_pizza' }.to_json,
          headers: { 'Content-Type' => 'application/json' } }
      end

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, mode: 'live')
      body = captured.first
      prompt = body['system_prompt']

      # Mesma FORMA de blocos que qualquer playbook (Maya inclusa) produziria — objective/rules
      # (Ai::StepInstructionText), validação de foco, próxima etapa. A extração JSON (collect.attribute)
      # não vem mais em texto no prompt (19/08) — vai no payload, pro schema (orchestrator.py).
      expect(prompt).to include('ETAPA ATUAL:')
      expect(prompt).to include('Objetivo: Descobrir o sabor da pizza que o cliente quer.')
      expect(prompt).to include('Regras:')
      expect(prompt).to include('- Se o cliente pedir "surpresa", sugira o sabor mais vendido do dia.')
      expect(prompt).not_to include('REGRA DE EXTRAÇÃO JSON')
      expect(body['collect_hint']).to eq('attributes' => ['sabor_pizza'], 'type' => 'text', 'options' => [], 'required' => true)
      expect(prompt).to include('REGRAS DE FOCO E VALIDAÇÃO DA COLETA')
      expect(prompt).to include('PRÓXIMA ETAPA')
      expect(prompt).to include('Confirmar o endereço de entrega.')

      # Nenhum vocabulário da Maya vaza pro prompt de um playbook que nunca o declarou -- prova de que
      # não há fallback/hardcode escondido puxando texto de outro domínio. Os nomes abaixo não têm
      # overlap nenhum com o vocabulário deste playbook (pizza).
      %w[cidade viabilidade plano_escolhido documento_cpf aparelhos_conectados tamanho_imovel].each do |maya_word|
        expect(prompt).not_to include(maya_word)
      end
    end
  end

  # tools_schema só manda o que REALMENTE chega à OpenAI (Structured Outputs, orchestrator.py): tools
  # reais do agente + consultar_conhecimento (condicional). "registrar_*"/as 5 tools de controle
  # foram removidas (17/08) — eram calculadas e mandadas todo turno só pro Python descartar antes de
  # montar a lista pra OpenAI (puro overhead Rails->Python, confirmado que nada no lado Rails
  # dependia desse catálogo enviado — Api::Internal::AiExecuteToolController resolve tudo por
  # constante/DB, não reconsultando isto).
  describe 'tools_schema traz só as tools que realmente chegam à OpenAI' do
    it 'inclui a tool real do agente, mas nenhuma "registrar_*"/tool de controle' do
      Ai::Playbook.create!(agent: agent, steps: [
        { 'name' => 'Boas-vindas', 'instructions' => 'Cumprimente com calor.' },
        { 'name' => 'Endereço', 'instructions' => 'Peça o endereço completo.',
          'collect' => { 'attribute' => 'endereco', 'type' => 'text' } }
      ])
      conversation.update!(additional_attributes: conversation.additional_attributes.merge('ai_step_index' => 1))
      Ai::Tool.create!(account: account, ai_agent_id: agent.id, name: 'conversation.add_label',
                       implementation_type: 'capability', capability_key: 'conversation.add_label', status: 'active')
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        body = JSON.parse(req.body)
        names = body['tools_schema'].map { |t| t['name'] }
        # Nome SANITIZADO (Ai::ToolNameSanitizer): "conversation.add_label" vira "_" — a OpenAI rejeita
        # ponto no nome da function (ver spec do sanitizer). A instrução narrativa continua ancorada só
        # na etapa ATIVA (índice 1) — isso não mudou, só o catálogo de tools.
        names == ['conversation_add_label'] &&
          body['system_prompt'].include?('Peça o endereço completo.') &&
          !body['system_prompt'].include?('Cumprimente com calor.')
      }
    end

    it 'sem nenhuma tool real nem conhecimento cadastrado, tools_schema vai vazio' do
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        JSON.parse(req.body)['tools_schema'] == []
      }
    end
  end

  # Pedido do usuário: mesmo padrão achado no fluxo n8n Maya v4.0 — manda objetivo + texto da PRÓXIMA
  # etapa junto no system_prompt, não só a atual. Reusa Ai::StateManager#next_step (já existia pro
  # look-ahead de conhecimento do motor legado).
  describe 'PRÓXIMA ETAPA no system_prompt (next_step_instructions)' do
    it 'inclui a próxima etapa, DEPOIS da ETAPA ATUAL, quando existe uma' do
      Ai::Playbook.create!(agent: agent, steps: [
        { 'name' => 'Boas-vindas', 'objective' => 'Cumprimentar.' },
        { 'name' => 'CPF', 'objective' => 'Peça o CPF.', 'collect' => { 'attribute' => 'cpf' } },
        { 'name' => 'Endereço', 'objective' => 'Peça o endereço.' }
      ])
      conversation.update!(additional_attributes: conversation.additional_attributes.merge('ai_step_index' => 1))
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, mode: 'live')

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
      Ai::Playbook.create!(agent: agent, steps: [
        { 'name' => 'CPF', 'objective' => 'Peça o CPF.', 'collect' => { 'attribute' => 'cpf' } },
        { 'name' => 'Endereço', 'objective' => 'Peça o endereço.' }
      ])
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, mode: 'live')

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
      Ai::Playbook.create!(agent: agent, steps: [
        { 'name' => 'Comprovante', 'objective' => 'Peça o comprovante.', 'collect' => { 'attribute' => 'comprovante' } },
        { 'name' => 'Finalização', 'objective' => 'Confirmar e transferir.',
          'rules' => ["Chame a ferramenta de transferência para atendente com o motivo 'conclusao_do_processo'."] }
      ])
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        prompt = JSON.parse(req.body)['system_prompt']
        prompt.include?('NÃO execute nenhuma ação ou ferramenta que ela descreva') &&
          prompt.include?('mesmo que você já tenha todos os dados que a próxima etapa pediria')
      }
    end

    it 'não aparece na ÚLTIMA etapa (não há próxima)' do
      Ai::Playbook.create!(agent: agent, steps: [
        { 'name' => 'Única', 'objective' => 'Só isso.' }
      ])
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        !JSON.parse(req.body)['system_prompt'].include?('PRÓXIMA ETAPA')
      }
    end

    it 'não aparece sem playbook nenhum' do
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        !JSON.parse(req.body)['system_prompt'].include?('PRÓXIMA ETAPA')
      }
    end
  end

  # Ponto do usuário: o admin só escreve Objetivo/Regras em linguagem natural na tela da etapa —
  # "JSON"/"dados_coletados" nunca deveriam vir da BOCA do admin. Esta regra é montada pelo Rails a
  # partir do "Dado que esta etapa coleta" (o mesmo Select/collect.attribute), nomeando a chave exata
  # que a IA deve preencher em "dados_coletados" NESTA etapa — sem o admin nunca digitar isso.
  #
  # Pedido do dono da conta (19/08): isto NÃO vai mais em texto no system_prompt — sai como o campo
  # collect_hint do payload (#collect_hint_for_schema), e é o Python (_collect_hint_text, ver
  # ai-orchestrator/test_reply_schema.py) quem monta a description do campo "dados_coletados" no
  # json_schema com essa informação, por chamada.
  describe 'collect_hint (collect_hint_for_schema — nomeia o collect.attribute da etapa ATUAL pro schema)' do
    it 'nomeia o attribute declarado no collect da etapa ativa' do
      Ai::Playbook.create!(agent: agent, steps: [
        { 'name' => 'Boas-vindas', 'instructions' => 'Cumprimente.' },
        { 'name' => 'CPF', 'instructions' => 'Peça o CPF.', 'collect' => { 'attribute' => 'cpf', 'type' => 'text' } }
      ])
      conversation.update!(additional_attributes: conversation.additional_attributes.merge('ai_step_index' => 1))
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        body = JSON.parse(req.body)
        body['collect_hint'] ==
          { 'items' => [{ 'attribute' => 'cpf', 'type' => 'text', 'options' => [], 'required' => true, 'hint' => nil }] } &&
          !body['system_prompt'].include?('REGRA DE EXTRAÇÃO JSON')
      }
    end

    it 'numa etapa informativa (sem collect), vem com items vazio' do
      Ai::Playbook.create!(agent: agent, steps: [
        { 'name' => 'Boas-vindas', 'instructions' => 'Cumprimente.' }
      ])
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        JSON.parse(req.body)['collect_hint'] == { 'items' => [] }
      }
    end

    it 'sem playbook nenhum, vem com items vazio (current_step é nil)' do
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        JSON.parse(req.body)['collect_hint'] == { 'items' => [] }
      }
    end

    # Pedido do usuário (validação de formato): a IA só consegue validar CPF/telefone/escolha/etc.
    # contra o tipo/opções REAIS da etapa se essa informação chegar — sem isso ela só tem o nome do
    # atributo. tools_schema tinha essa info (input_schema de "registrar_*"), mas essa tool é filtrada
    # antes de chegar à OpenAI no motor Python; collect_hint é quem preenche a lacuna agora.
    it 'inclui tipo/opções/obrigatoriedade do slot (pro contexto de validação de formato)' do
      Ai::Playbook.create!(agent: agent, steps: [
        { 'name' => 'Plano', 'instructions' => 'Pergunte o plano.',
          'collect' => { 'attribute' => 'plano', 'type' => 'choice', 'options' => %w[Fibra 5G] } }
      ])
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        JSON.parse(req.body)['collect_hint'] == { 'items' => [
          { 'attribute' => 'plano', 'type' => 'choice', 'options' => %w[Fibra 5G], 'required' => true, 'hint' => nil }
        ] }
      }
    end

    it 'campo opcional (slot_required: false): required vem false' do
      Ai::Playbook.create!(agent: agent, steps: [
        { 'name' => 'Indicação', 'instructions' => 'Pergunte se tem indicação.', 'slot_required' => false,
          'collect' => { 'attribute' => 'indicacao', 'type' => 'text' } }
      ])
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        JSON.parse(req.body)['collect_hint'] == { 'items' => [
          { 'attribute' => 'indicacao', 'type' => 'text', 'options' => [], 'required' => false, 'hint' => nil }
        ] }
      }
    end

    # Achado ao vivo (16/08, ticket 586): collect.attribute = ['cidade', 'viabilidade'] (2 atributos
    # numa etapa só) fazia o prompt nomear UMA chave colada '["cidade", "viabilidade"]' — a IA só tinha
    # instrução pra escrever essa chave colada, nunca as duas reais que a validação de avanço
    # (Api::Internal::AiExecuteToolController#collect_attributes) exigia separadas. A etapa nunca
    # completava: avancar_etapa vinha true, mas o índice nunca avançava, e o teto de "travado"
    # (stuck_handoff_turns) ia subindo turno a turno até estourar — sem nada de errado visível na
    # conversa. Agora collect_hint lista as DUAS chaves reais, cada uma como item PRÓPRIO — type/options
    # continuam compartilhados entre os dois (é o que o formato ANTIGO de collect guarda: um único
    # type/options pro collect inteiro, nunca por atributo — ver Ai::StepSlot#items_from_legacy_collect).
    it 'etapa com MAIS de um atributo declarado (formato antigo, array): nomeia CADA atributo real como item próprio, nunca uma chave colada' do
      Ai::Playbook.create!(agent: agent, steps: [
        { 'name' => 'Cidade', 'instructions' => 'Peça a cidade e verifique a viabilidade.',
          'collect' => { 'attribute' => %w[cidade viabilidade], 'options' => %w[Chapecó Maravilha] } }
      ])
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        JSON.parse(req.body)['collect_hint'] == { 'items' => [
          { 'attribute' => 'cidade', 'type' => 'text', 'options' => %w[Chapecó Maravilha], 'required' => true, 'hint' => nil },
          { 'attribute' => 'viabilidade', 'type' => 'text', 'options' => %w[Chapecó Maravilha], 'required' => true, 'hint' => nil }
        ] }
      }
    end

    # "DADOS PARA COLETA NA ETAPA" (collect.items[]): CADA dado com SEU PRÓPRIO type/required/hint —
    # CPF obrigatório e e-mail opcional na MESMA etapa, cada um validado com o formato certo, em vez de
    # os dois caírem no genérico "obrigatório/opcional" que o formato antigo aplicava com 2+ atributos.
    it 'formato collect.items[]: cada dado leva SEU type/required/hint no collect_hint enviado ao Python' do
      Ai::Playbook.create!(agent: agent, steps: [
        { 'name' => 'Dados do cliente', 'instructions' => 'Colete CPF, nome e e-mail.',
          'collect' => { 'items' => [
            { 'attribute' => 'cpf_cliente', 'type' => 'cpf', 'required' => true },
            { 'attribute' => 'nome_cliente', 'type' => 'text', 'required' => true },
            { 'attribute' => 'email_cliente', 'type' => 'email', 'required' => false, 'hint' => 'para nota fiscal' }
          ] } }
      ])
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        JSON.parse(req.body)['collect_hint'] == { 'items' => [
          { 'attribute' => 'cpf_cliente', 'type' => 'cpf', 'options' => [], 'required' => true, 'hint' => nil },
          { 'attribute' => 'nome_cliente', 'type' => 'text', 'options' => [], 'required' => true, 'hint' => nil },
          { 'attribute' => 'email_cliente', 'type' => 'email', 'options' => [], 'required' => false, 'hint' => 'para nota fiscal' }
        ] }
      }
    end
  end

  # Pedido do usuário: apertar o foco (só o dado da etapa, exceto front-loading válido) + validar
  # formato por tipo antes de gravar + escalar (esclarecer 1x, depois transferir/aceitar vazio).
  describe 'REGRAS DE FOCO E VALIDAÇÃO DA COLETA (data_validation_instruction)' do
    it 'inclui foco na etapa atual, exceção de front-loading, valor-não-frase, e referência de formato por tipo' do
      Ai::Playbook.create!(agent: agent, steps: [
        { 'name' => 'CPF', 'instructions' => 'Peça o CPF.', 'collect' => { 'attribute' => 'cpf', 'type' => 'text' } }
      ])
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, mode: 'live')

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
      Ai::Playbook.create!(agent: agent, steps: [
        { 'name' => 'Cidade', 'instructions' => 'Peça a cidade.',
          'collect' => { 'attribute' => %w[cidade viabilidade] } }
      ])
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, mode: 'live')

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
      Ai::Playbook.create!(agent: agent, steps: [
        { 'name' => 'CPF', 'instructions' => 'Peça o CPF.', 'collect' => { 'attribute' => 'cpf', 'type' => 'text' } }
      ])
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        prompt = JSON.parse(req.body)['system_prompt']
        prompt.include?('NÃO marque "transferir_humano" só pela quantidade de tentativas') &&
          prompt.include?('mande "dados_coletados" vazio ([]) e defina "avancar_etapa": true') &&
          !prompt.include?('campo OBRIGATÓRIO → defina "transferir_humano": true')
      }
    end

    it 'não aparece numa etapa informativa (sem collect) — nada pra validar' do
      Ai::Playbook.create!(agent: agent, steps: [
        { 'name' => 'Boas-vindas', 'instructions' => 'Cumprimente.' }
      ])
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, mode: 'live')

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
      Ai::Playbook.create!(agent: agent, steps: [
        { 'name' => 'Nome', 'objective' => 'Coletar o nome.',
          'rules' => ['Assim que o cliente informar o nome, chame a ferramenta registrar_nome_cliente.'],
          'collect' => { 'attribute' => 'nome_cliente' } }
      ])
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        prompt = JSON.parse(req.body)['system_prompt']
        prompt.include?('Assim que o cliente informar o nome, inclua esse dado em "dados_coletados" no seu JSON de resposta.') &&
          !prompt.include?('chame a ferramenta registrar_nome_cliente') &&
          !prompt.include?('registrar_nome_cliente')
      }
    end

    # Achado ao vivo 2 (17/08, ticket 599 período de instalação): a regra da etapa dizia "...registre
    # o período na variável periodo_reservado USANDO a ferramenta registrar_periodo_reservado..." — o
    # verbo era "usando", não "chame", e a regex antiga só cobria "chame". A IA nunca escreveu o dado
    # em "dados_coletados" (a tool não existe mais), mas a mensagem "vou reservar" saiu normal — sem
    # erro visível, o dado só se perdia.
    it 'reescreve "usando a ferramenta registrar_X" (verbo diferente de "chame") preservando o critério ao redor' do
      Ai::Playbook.create!(agent: agent, steps: [
        { 'name' => 'Período', 'objective' => 'Reservar o período.',
          'rules' => ['Registre o período na variável periodo_reservado usando a ferramenta registrar_periodo_reservado.'],
          'collect' => { 'attribute' => 'periodo_reservado' } }
      ])
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        prompt = JSON.parse(req.body)['system_prompt']
        prompt.include?('Registre o período na variável periodo_reservado inclua esse dado em "dados_coletados" no seu JSON de resposta.') &&
          !prompt.include?('registrar_periodo_reservado')
      }
    end

    it 'reescreve "chame a ferramenta avancar_etapa" preservando o critério ao redor' do
      Ai::Playbook.create!(agent: agent, steps: [
        { 'name' => 'Nome', 'objective' => 'Coletar o nome.',
          'rules' => ['Assim que tiver capturado o nome, chame a ferramenta avancar_etapa.'] }
      ])
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        prompt = JSON.parse(req.body)['system_prompt']
        prompt.include?('Assim que tiver capturado o nome, defina "avancar_etapa": true no seu JSON de resposta.') &&
          !prompt.include?('chame a ferramenta avancar_etapa')
      }
    end

    it 'NÃO mexe em referência a uma tool REAL (admin-configurada) na etapa' do
      Ai::Tool.create!(account: account, ai_agent_id: agent.id, name: 'consultar_periodos',
                       implementation_type: 'capability', capability_key: 'x.y', status: 'active', description: 'x')
      Ai::Playbook.create!(agent: agent, steps: [
        { 'name' => 'Períodos', 'objective' => 'Informar períodos disponíveis.',
          'rules' => ['Antes de responder, chame a ferramenta consultar_periodos.'] }
      ])
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        JSON.parse(req.body)['system_prompt'].include?('chame a ferramenta consultar_periodos')
      }
    end
  end

  # Pedido do dono da conta (19/08): transfer_when/close_when/close_message saíram do texto do
  # system_prompt e passam a viajar como campos próprios do payload — é o Python
  # (_build_reply_schema, orchestrator.py) quem os interpola na description de
  # transferir_humano/encerrar_atendimento do json_schema, por chamada. Ver ai-orchestrator/
  # test_reply_schema.py pra cobertura desse lado.
  describe 'payload traz transfer_when/close_when/close_message (pro schema dinâmico do Python)' do
    it 'manda transfer_when/close_when (do playbook) e close_message (do agente)' do
      Ai::Playbook.create!(agent: agent, transfer_when: ['cliente pede humano'],
                           close_when: ['cliente confirma que não quer mais nada'])
      agent.update!(close_rules: { 'message' => 'Foi um prazer te atender!' })
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, mode: 'live')

      # REGRAS: (structured_output_instruction) removida por completo (19/08, pedido do dono da conta —
      # ver comentário em Ai::PythonOrchestratorClient#system_prompt); o texto "Transfira para humano
      # quando"/"Encerre quando" não vai mais no prompt.
      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        body = JSON.parse(req.body)
        body['transfer_when'] == 'cliente pede humano' &&
          body['close_when'] == 'cliente confirma que não quer mais nada' &&
          body['close_message'] == 'Foi um prazer te atender!' &&
          !body['system_prompt'].include?('Transfira para humano quando:') &&
          !body['system_prompt'].include?('Encerre quando:') &&
          !body['system_prompt'].include?('REGRAS:')
      }
    end

    # Achado ao vivo (17/08, ticket 599): sem close_when configurado, a IA marcou
    # "encerrar_atendimento": true sozinha só porque o cliente disse "ta bem obrigada" — pulou etapas
    # inteiras (incluindo a de Finalização, cujo desfecho configurado era TRANSFERIR pra um humano, não
    # resolver). encerrar_atendimento_rule (que corrigia isso em texto) foi removida do Rails (19/08) —
    # a mesma proteção agora vive em orchestrator._build_reply_schema: sem close_when, a description do
    # campo vira uma proibição explícita ("mantenha SEMPRE false... NUNCA marque true por conta
    # própria"), não a genérica ambígua. Ver test_sem_close_when_vira_proibicao_explicita_nao_a_
    # description_generica_ambigua em ai-orchestrator/test_reply_schema.py.
    it 'sem close_when configurado, manda close_when nil pro Python (que aplica a proibição explícita)' do
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        body = JSON.parse(req.body)
        body['close_when'].nil? && !body['system_prompt'].include?('Encerre quando:')
      }
    end
  end

  describe 'force_handoff_notice (teto de segurança por etapa, decidido pelo Ai::Gateway)' do
    it 'quando true, injeta a instrução forçada de transferência imediata no system_prompt' do
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent,
                                      mode: 'live', force_handoff_notice: true)

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        JSON.parse(req.body)['system_prompt'].include?('LIMITE DE TENTATIVAS ATINGIDO')
      }
    end

    it 'default false — não injeta nada' do
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, mode: 'live')

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

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent,
                                      mode: 'live', message: message)

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL)
        .with(body: hash_including('image_urls' => ['https://cdn.example.com/foto.jpg']))
    end

    it 'image_urls vem [] quando não há mensagem/anexo de imagem nem documento escaneado' do
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, mode: 'live')

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

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent,
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

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent,
                                      mode: 'live', message: message)

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL)
        .with(body: hash_including('image_urls' => ['https://cdn.example.com/foto.jpg', 'data:image/png;base64,BBBB']))
    end
  end

  # Removido (17/08, decisão de produto): identity_instruction/market_average_guardrail (as guardrails
  # fixas de identidade/anti-concorrente) saíram do código — ver comentário em
  # Ai::PythonOrchestratorClient#system_prompt. Os 2 testes que verificavam sua posição/redação (1ª e
  # 3ª linha, condicional a has_knowledge?) saíram junto — testavam comportamento que não existe mais.
  describe 'identidade + conhecimento no system_prompt' do
    # Regressão achada ao vivo 13/08 (Maya v5.0, identify_as='human'): esta instrução existia no
    # Ai::PromptCompiler legado (identity_lines) e nunca foi portada pro Python — o split em várias
    # mensagens (Ai::ActionDispatcher#split_parts) continuava funcionando no código, mas o modelo
    # nunca era instruído a produzir "\n\n" em mensagem_para_cliente, então não tinha o que quebrar.
    # Reposicionada (17/08) pra perto do topo do system_prompt. "Você é <nome>." saiu de vez (18/08,
    # pedido de redução de prompt — texto livre do admin não estava marcado pra ficar, ver comentário em
    # Ai::PythonOrchestratorClient#system_prompt) e handoff_target_instruction foi removida por completo
    # (mesmo pedido — ver describe 'Times disponíveis' mais abaixo). Remanejada de novo (19/08, pedido do
    # dono da conta): agora vai DEPOIS do "prompt geral do agente" (base_prompt) — antes vinha antes.
    # Vira lines[1] quando o agente TEM base_prompt (o default do factory tem); lines[0] só se o agente
    # não tiver base_prompt configurado.
    describe 'identify_as_instruction (depois do base_prompt no system_prompt)' do
      it 'identify_as="human" (default do agent): instrui a quebrar em mensagens curtas com linha em branco' do
        agent.update!(identify_as: 'human')
        stub_orchestrator

        described_class.process_message(conversation: conversation, content: 'oi', agent: agent, mode: 'live')

        # "Não diga que é uma inteligência artificial" saiu (18/08, pedido de redução de prompt) — ver
        # comentário em Ai::PythonOrchestratorClient#identify_as_instruction (risco assumido).
        expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
          prompt = JSON.parse(req.body)['system_prompt']
          line = prompt.lines[1]
          prompt.lines[0].strip == agent.base_prompt &&
            line.include?('Aja como um atendente humano da equipe') &&
            line.include?('LINHA EM BRANCO entre elas (dois \n)') &&
            line.include?('"mensagem_para_cliente"')
        }
      end

      it 'identify_as="ai": NÃO instrui a quebrar em várias mensagens, pode se assumir IA' do
        agent.update!(identify_as: 'ai')
        stub_orchestrator

        described_class.process_message(conversation: conversation, content: 'oi', agent: agent, mode: 'live')

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
                                      agent: agent, mode: 'live')

      expect(Ai::KnowledgeRetriever).not_to have_received(:retrieve)
    end

    it 'NÃO injeta mais o bloco fixo "## CONHECIMENTO OFICIAL DA EMPRESA" — a IA busca via tool' do
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'quanto custa o plano fibra?',
                                      agent: agent, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        !JSON.parse(req.body)['system_prompt'].include?('## CONHECIMENTO OFICIAL DA EMPRESA')
      }
    end

    it 'a tool "consultar_conhecimento" entra em tools_schema quando o agente TEM conhecimento cadastrado, com "pergunta" obrigatória' do
      add_knowledge!
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, mode: 'live')

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

    # Pedido do usuário: sem NENHUM conhecimento cadastrado pro agente, a tool nem entra no array
    # — oferecer uma ferramenta que sempre volta vazia só ensina a IA a gastar uma rodada de tool-call
    # à toa. Mesma conta/agente de todos os outros testes deste arquivo (nenhum cadastra
    # Ai::KnowledgeSource por padrão), então este teste também documenta o comportamento default.
    it 'a tool "consultar_conhecimento" NÃO entra em tools_schema sem nenhum conhecimento cadastrado' do
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        JSON.parse(req.body)['tools_schema'].none? { |t| t['name'] == 'consultar_conhecimento' }
      }
    end

    # Uma fonte cadastrada mas ainda sem chunk indexado (ingest ainda não rodou, ou raw vazio) conta
    # como "sem conhecimento" — a ferramenta só ajuda quando há o que buscar de verdade.
    it 'a tool "consultar_conhecimento" NÃO entra em tools_schema quando a fonte existe mas ainda não tem chunk indexado' do
      allow(Ai::KnowledgeIngestJob).to receive(:perform_later)
      Ai::KnowledgeSource.create!(account: account, ai_agent_id: agent.id, kind: 'faq', title: 'FAQ')
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        JSON.parse(req.body)['tools_schema'].none? { |t| t['name'] == 'consultar_conhecimento' }
      }
    end

    # Conhecimento COMPARTILHADO da conta (ai_agent_id nil) também conta — mesmo escopo que
    # Ai::KnowledgeRetriever#source_ids_for usa pra buscar de verdade.
    it 'a tool "consultar_conhecimento" entra em tools_schema quando o conhecimento é compartilhado da conta (sem agente específico)' do
      allow(Ai::KnowledgeIngestJob).to receive(:perform_later)
      source = Ai::KnowledgeSource.create!(account: account, kind: 'faq', title: 'FAQ geral')
      Ai::KnowledgeChunk.create!(ai_knowledge_source_id: source.id, content: 'Horário de atendimento: 9h às 18h.', embedding: nil)
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        JSON.parse(req.body)['tools_schema'].any? { |t| t['name'] == 'consultar_conhecimento' }
      }
    end

    it 'vector_store_id continua sendo lido de agent.behavior e enviado (auditoria: sempre vazio na prática, mas o código está correto)' do
      agent.update!(behavior: { 'vector_store_id' => 'vs_abc123' })
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, mode: 'live')

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
      Ai::Playbook.create!(agent: agent, steps: [{ 'name' => 'Boas-vindas', 'objective' => 'Cumprimentar.' }])
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, mode: 'live')

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

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        !JSON.parse(req.body)['system_prompt'].include?('DADOS JÁ COLETADOS')
      }
    end

    it 'sem ai_collected_facts (conversa nova): o bloco não aparece' do
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        !JSON.parse(req.body)['system_prompt'].include?('DADOS JÁ COLETADOS')
      }
    end

    # Gap 1 do caminho legado: Ai::StepSlot::ABSENT ('__sem_valor__') é um TOKEN interno — nunca pode
    # vazar cru pro modelo (motivo: pode ter sido gravado pelo motor legado nesta MESMA conversa, se o
    # agente alternou o flag python_orchestrator no meio do atendimento).
    it 'valor ABSENT (recusa do motor legado) aparece como "não informado", NUNCA o token cru' do
      with_facts('cpf' => Ai::StepSlot::ABSENT)
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, mode: 'live')

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

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent,
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

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent,
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

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, mode: 'live')

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
  #
  # Pedido do dono da conta (18/08, redução de prompt; 19/08, remoção completa do bloco inteiro) — ver
  # comentário em Ai::PythonOrchestratorClient#system_prompt. Risco assumido: exatamente a classe de
  # bug descrita acima pode voltar. Testes viram guarda de que o corte foi o pretendido (não um
  # esquecimento futuro) — se a regra voltar, troque de volta pra "prompt.include?".
  describe 'PROIBIÇÃO de "fake-transfer"/"fake-close" (dizer sem marcar o campo) — REMOVIDA (18/08)' do
    it 'NÃO proíbe mais alegar transferência sem marcar transferir_humano+handoff_summary' do
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        prompt = JSON.parse(req.body)['system_prompt']
        !prompt.include?('É ESTRITAMENTE PROIBIDO escrever em "mensagem_para_cliente" qualquer variação de "vou transferir"')
      }
    end

    it 'NÃO proíbe mais alegar encerramento sem marcar encerrar_atendimento' do
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        prompt = JSON.parse(req.body)['system_prompt']
        !prompt.include?('É ESTRITAMENTE PROIBIDO escrever em "mensagem_para_cliente" qualquer variação de "atendimento encerrado"')
      }
    end
  end

  # Removido (17/08, decisão de produto): as guardrails fixas de não-inventar/disciplina de
  # transferência/erro de ferramenta/cadência de pergunta saíram do código (ver comentário em
  # Ai::PythonOrchestratorClient#system_prompt) — os 4 testes que verificavam sua redação saíram
  # junto.
  #
  # Pedido do dono da conta (18/08, redução de prompt; 19/08, remoção completa do bloco inteiro) — a
  # regra de "fake-save" abaixo (não fingir que salvou sem preencher "dados_coletados") TAMBÉM foi
  # removida — ver comentário em Ai::PythonOrchestratorClient#system_prompt. Risco assumido: o bug real
  # que essa regra corrigia (dado perdido silenciosamente) pode voltar.
  describe 'contrato JSON estruturado (achados em teste ao vivo)' do
    # Bug real ao vivo, round 2 (era do design de tool-calling): a IA chamava "continuar_conversa" (o
    # no-op que sustentava tool_choice="required") e dizia em texto "Recebi seu CPF!" sem NUNCA chamar
    # registrar_*/salvar_memoria_ia — nada persistia, a etapa seguinte repetia a pergunta (loop de
    # dados). Guarda de que a remoção foi intencional — se a regra voltar, troque de volta pra
    # "prompt.include?".
    it 'NÃO proíbe mais alegar que salvou sem preencher "dados_coletados" (regra removida, 18/08)' do
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'meu cpf é 123', agent: agent, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        prompt = JSON.parse(req.body)['system_prompt']
        !prompt.include?('É ESTRITAMENTE PROIBIDO dizer em "mensagem_para_cliente" que recebeu/anotou um dado')
      }
    end

    # Bug real ao vivo (WhatsApp), 2 rodadas: cliente disse "vendas", a IA respondeu "Perfeito, é
    # vendas mesmo?" em loop, sem nunca registrar/avançar. A regra que corrigia isso em texto
    # (structured_output_instruction) foi REMOVIDA por completo (19/08, pedido do dono da conta — ver
    # comentário em Ai::PythonOrchestratorClient#system_prompt). RISCO: nenhuma description de campo do
    # json_schema cobre "não peça confirmação, registre e avance NA MESMA resposta" — esse bug pode
    # voltar. Guarda de que a remoção foi intencional — se a regra voltar, troque de volta pra
    # "prompt.include?".
    it 'NÃO proíbe mais pedir confirmação em loop (regra removida, 19/08)' do
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'vendas', agent: agent, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        prompt = JSON.parse(req.body)['system_prompt']
        !prompt.include?("NÃO peça confirmação ('é isso mesmo?', 'posso confirmar?')")
      }
    end

    it 'NÃO inclui nenhuma instrução de "uma mensagem só" (múltiplas mensagens por turno é o modo identify_as="human", intencional)' do
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        !JSON.parse(req.body)['system_prompt'].include?('APENAS UMA mensagem por turno')
      }
    end
  end

  # Resumo de transferência: a IA preenche "handoff_summary" no próprio JSON estruturado (campo do
  # STRUCTURED_REPLY_SCHEMA em orchestrator.py, não mais input_schema de tool — conversation_transfer
  # não é mais oferecida em tools_schema), e o controller salva em
  # additional_attributes['handoff_summary'] (ver spec/requests/api/internal/ai_execute_tool_controller_spec.rb
  # pro lado da gravação).
  describe 'handoff_summary na transferência' do
    it 'system_prompt instrui a IA a SEMPRE preencher handoff_summary ao transferir' do
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        JSON.parse(req.body)['system_prompt'].include?('preencha "handoff_summary" com o que já foi conseguido')
      }
    end
  end

  # Achado ao vivo (17/08): o motor Ruby legado deixava a IA nomear o TIME de destino do handoff
  # (handoff_target, casado contra a whitelist agent.handoff_team_ids — Ai::PromptCompiler
  # #human_handoff_teams) — o Structured Outputs nunca reproduziu isso, então toda transferência direta
  # caía sempre no mesmo time default, cega à intenção. Reusa a MESMA função pura do motor legado.
  # Pedido do dono da conta (18/08, redução de prompt): handoff_target_instruction foi REMOVIDA de vez
  # (não só a whitelist — o método inteiro) — ver comentário em
  # Ai::PythonOrchestratorClient#system_prompt e em Api::Internal::AiExecuteToolController#transfer_to_human
  # (risco assumido: reverte o achado de 17/08 pra contas com 2+ times marcados).
  describe 'Times disponíveis (handoff_target_instruction) — REMOVIDA (18/08)' do
    it 'NÃO lista mais os times da whitelist nem instrui a preencher handoff_target' do
      team_a = create(:team, account: account, name: 'Suporte Técnico')
      team_b = create(:team, account: account, name: 'Financeiro')
      agent.update!(handoff_team_ids: [team_a.id, team_b.id])
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        prompt = JSON.parse(req.body)['system_prompt']
        !prompt.include?('handoff_target') && !prompt.include?('Suporte Técnico') && !prompt.include?('Financeiro')
      }
    end

    it 'sem NENHUM time na conta, também não aparece (nada pra IA escolher)' do
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        !JSON.parse(req.body)['system_prompt'].include?('handoff_target')
      }
    end
  end

  # Achado ao vivo (17/08, ticket 595): a IA perguntou "cidade" (assunto de tool real, não de nenhuma
  # etapa alcançada) por conta própria — tools reais ficam sempre disponíveis, sem gate por etapa.
  describe 'DISCIPLINA DE FERRAMENTAS (tool_discipline_instruction)' do
    it 'com tool real configurada, instrui a só usá-la quando a etapa atual pedir' do
      Ai::Tool.create!(account: account, ai_agent_id: agent.id, name: 'Consultar_Viabilidade',
                       implementation_type: 'capability', capability_key: 'conversation.add_label', status: 'active')
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        JSON.parse(req.body)['system_prompt'].include?('DISCIPLINA DE FERRAMENTAS')
      }
    end

    it 'sem NENHUMA tool real configurada, não aparece (nada pra disciplinar)' do
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        !JSON.parse(req.body)['system_prompt'].include?('DISCIPLINA DE FERRAMENTAS')
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

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, mode: 'live')

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

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        !JSON.parse(req.body)['system_prompt'].include?('MEMÓRIA DESTE CLIENTE')
      }
    end
  end

  # "salvar_memoria_ia": webhook que orchestrator.py chama por baixo pra CADA item de
  # "dados_coletados" sem tool dedicada — não é mais oferecida como tool à OpenAI (tools_schema não
  # manda mais "registrar_*"/tools de controle, ver comentário em
  # Ai::PythonOrchestratorClient#tools_schema). O MECANISMO continua (o campo "dados_coletados" segue
  # obrigatório no json_schema estrito do lado Python) — a frase explicando chave/valor/atualiza-não-
  # duplica saiu do prompt (18/08, pedido de redução; o bloco inteiro foi removido em 19/08 — ver
  # comentário em Ai::PythonOrchestratorClient#system_prompt).
  describe 'catch-all de memória ("dados_coletados" -> salvar_memoria_ia no Python)' do
    # Structured Outputs: a IA não escolhe mais entre "registrar_*" e "salvar_memoria_ia" — todo dado
    # (com ou sem tool dedicada no design antigo) vai pro mesmo lugar, "dados_coletados"; é o Python
    # (orchestrator.py#_dispatch_structured_reply) quem sempre chama o webhook salvar_memoria_ia por
    # baixo, pra CADA item da lista, sem a IA precisar saber que essa tool existe.
    it 'NÃO explica mais em detalhe como preencher "dados_coletados" (frase removida, 18/08)' do
      stub_orchestrator

      described_class.process_message(conversation: conversation, content: 'oi', agent: agent, mode: 'live')

      expect(WebMock).to have_requested(:post, described_class::ORCHESTRATOR_URL).with { |req|
        !JSON.parse(req.body)['system_prompt'].include?('adicione UM ITEM em "dados_coletados"')
      }
    end
  end

end
