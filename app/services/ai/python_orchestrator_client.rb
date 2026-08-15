# Bridges Ai::Gateway to the Python AI orchestrator microservice, which owns the OpenAI Responses
# API reasoning/tool-call loop for a turn (native OpenAI tools like file_search resolved entirely
# in Python; Rails-side tools proxied back via Api::Internal::AiExecuteToolController). Replaces
# Ai::ContextBuilder + Ai::ModelRouter for departments opted into this path — Gateway keeps billing,
# department resolution and final delivery (Ai::ActionDispatcher) exactly as before.
#
# History: no flattened message blob is sent. conversation_id (an OpenAI Conversations API id,
# conv_..., persistent and non-expiring — reused from the SAME
# conversation.additional_attributes['openai_conversation_id'] field the existing decide()/
# call_with_tools() paths already read/write) lets OpenAI keep the full turn history server-side.
#
# Agentic flow (deliberate, replaces an earlier "only the current step's tool" design that was tried
# and rejected — it forced the AI to ignore data the customer front-loaded): the model gets ALL
# "registrar_*" capture tools every turn AND controls its own progress via "avancar_etapa" — Rails
# never blocks which tool is offered, only reacts to which ones get called
# (Api::Internal::AiExecuteToolController, Ai::Gateway). system_prompt still anchors the model to the
# CURRENT step's instructions text (server-tracked ai_step_index) so the conversation has a narrative
# thread, but that never gates which data can be captured.
#
# SUPERSEDED (kept for history): tool_choice="required" + CONTINUE_TOOL ("continuar_conversa") used to
# force a tool call every turn so the AI couldn't reply with text-only confirmation loops that never
# advanced ai_step_index — and CONTINUE_TOOL existed as the safe no-op for turns with nothing to save.
# That mechanism had a round-2 failure mode, live and worse: the AI abused CONTINUE_TOOL to satisfy
# tool_choice="required" cheaply while claiming in TEXT ("Recebi seu CPF!") that it saved a real datum,
# without ever calling registrar_*/salvar_memoria_ia — nothing persisted, the next step re-asked
# (the data loop this whole class exists to prevent). Structured Outputs (orchestrator.py,
# text.format=json_object) replaced the entire mechanism: the model's ONLY output is now the JSON
# contract in #structured_output_instruction, and Python (not the model's tool choice) decides
# save/advance/transfer/close from what's actually IN that JSON. CONTINUE_TOOL/ADVANCE_STEP_TOOL/
# MEMORY_TOOL/RESOLVE_TOOL/TRANSFER_TOOL constants are still used as the tool_name strings Python posts
# to Api::Internal::AiExecuteToolController (unchanged), just never offered to OpenAI as callable tools
# anymore (orchestrator.py filters them out before building the tools list).
class Ai::PythonOrchestratorClient
  # Normalizes AI_ORCHESTRATOR_URL whether or not it already includes the /process path — an env var
  # pointed at just the service root (e.g. http://ai-orchestrator:8000) was POSTing to '/' and 404ing.
  # Idempotent: a URL that already ends in /process (with or without a trailing slash) passes through.
  def self.build_orchestrator_url(raw)
    base = raw.to_s.chomp('/')
    base.end_with?('/process') ? base : "#{base}/process"
  end

  ORCHESTRATOR_URL = build_orchestrator_url(ENV.fetch('AI_ORCHESTRATOR_URL', 'http://localhost:8000'))
  TIMEOUT = 60

  # control tool names — shared with Api::Internal::AiExecuteToolController, which recognizes these
  # by name (not backed by an Ai::Tool row) exactly like Ai::StepCaptureTool's "registrar_*".
  ADVANCE_STEP_TOOL = 'avancar_etapa'
  RESOLVE_TOOL = 'conversation.resolve'
  TRANSFER_TOOL = 'conversation.transfer'
  # Legado (Structured Outputs substituiu tool_choice="required" — ver #structured_output_instruction):
  # existia SÓ pra dar à IA uma opção válida quando orchestrator.py forçava alguma tool a cada turno.
  # Ainda gerada aqui e ainda reconhecida pelo controller (não quebra nada), mas orchestrator.py filtra
  # esta tool antes de montar a lista pra OpenAI — não é mais oferecida, não é mais chamada. O
  # controller NUNCA toca o banco por causa dela de qualquer forma (ver #continue_conversation).
  CONTINUE_TOOL = 'continuar_conversa'
  # Catch-all de memória (híbrida, deliberado — ver #memory_tool): complementa "registrar_*", não
  # substitui. Pra atributo JÁ conhecido (collect ou CustomAttributeDefinition), "registrar_*" é
  # SEMPRE a via certa — o nome da tool garante a chave exata, sem risco de a IA inventar uma chave
  # livre que não bate com o CustomAttributeDefinition e o espelhamento pra custom_attributes falhar
  # em silêncio (já aconteceu neste projeto uma vez, com o modelo escrevendo "cidade_usuario" em vez
  # de "cidade"). Esta tool é só pro que SOBRA: contexto que o cliente deu e não tem "botão" nenhum.
  MEMORY_TOOL = 'salvar_memoria_ia'
  # RAG agentic (substitui o bloco fixo #knowledge_block + o campo por-etapa "consultar conhecimento
  # antes de responder", que nunca era lido pelo motor Python — só existia na tela e ficava morto no
  # jsonb do step). Tool REAL de function-calling (não um control_tool de nome reservado): precisa do
  # loop de tool-call de verdade (orchestrator.py) porque o resultado tem que voltar pro MESMO turno,
  # antes da IA decidir a resposta final — diferente de avancar_etapa/salvar_memoria_ia, que Python
  # decide e dispara DEPOIS de já ter o JSON pronto. Disponível em TODA etapa, sempre — a IA decide
  # quando chamar (objetivo da etapa + o que o cliente perguntou), sem pré-configuração de query/kind.
  KNOWLEDGE_TOOL = 'consultar_conhecimento'

  def self.process_message(conversation:, content:, agent:, department:, mode:, message: nil, force_handoff_notice: false)
    new(conversation: conversation, content: content, agent: agent, department: department, mode: mode,
        message: message, force_handoff_notice: force_handoff_notice).perform
  end

  def initialize(conversation:, content:, agent:, department:, mode:, message: nil, force_handoff_notice: false)
    @conversation = conversation
    @content = content
    @agent = agent
    @department = department
    @mode = mode
    @message = message
    @force_handoff_notice = force_handoff_notice
  end

  def perform
    response = HTTParty.post(
      ORCHESTRATOR_URL,
      headers: {
        'Content-Type' => 'application/json',
        'Authorization' => "Bearer #{ENV.fetch('INTERNAL_AI_TOKEN', nil)}"
      },
      body: payload.to_json,
      timeout: TIMEOUT
    )

    unless response.success?
      Rails.logger.error "[Ai::PythonOrchestratorClient] HTTP #{response.code}: #{response.body}"
      return { reply: nil, conversation_id: nil, byok_fallback: false }
    end

    parsed = response.parsed_response
    { reply: parsed['reply'], conversation_id: parsed['conversation_id'], byok_fallback: parsed['byok_fallback'] == true }
  rescue StandardError => e
    Rails.logger.error "[Ai::PythonOrchestratorClient] #{e.class}: #{e.message}"
    { reply: nil, conversation_id: nil, byok_fallback: false }
  end

  private

  def payload
    {
      # Sent as integers, matching the orchestrator's Pydantic request model (ticket_id/ai_department_id: int).
      ticket_id: @conversation.id,
      ai_department_id: @department.id,
      mode: @mode,
      system_prompt: system_prompt,
      tools_schema: tools_schema,
      # SEMPRE vazio hoje — nada neste projeto cria/sincroniza um vector store da OpenAI (auditado:
      # nenhuma tela, nenhum job). Mantido (lido corretamente de department.behavior) para quando essa
      # sincronização existir; até lá, a base de conhecimento chega pela tool #knowledge_tool
      # (consultar_conhecimento — Ai::KnowledgeRetriever, pgvector, já populado).
      vector_store_id: @department.behavior.to_h['vector_store_id'],
      user_input: @content.to_s,
      # RAW pixels the model reads NATIVELY (not text captions folded into @content upstream in
      # Ai::Gateway): the WhatsApp photo's own url, if any, THEN the rasterized pages (base64 data
      # URIs) of any scanned-document PDF attachment (Ai::Workers::MediaProcessor.pending_vision_images
      # — CNH/RG/comprovante), so the SAME governed turn reads them instead of a separate, context-blind
      # captioning call (that's what misread a CNH's "1997" as "1991" live — see #document_image_urls).
      image_urls: image_urls,
      conversation_id: @conversation.additional_attributes&.dig('openai_conversation_id'),
      # Multi-tenant: cada Account escolhe seu próprio modelo/temperatura via Ai::OperationProfile
      # (tela de admin). nil quando o agente não tem perfil — o orquestrador cai no OPENAI_MODEL do
      # seu próprio .env e deixa a OpenAI usar o default de temperatura, não hardcodeia nada aqui.
      model: operation_profile&.supervisor_model,
      # Trafega desde já (logado no lado Python) — dispatch por provider ainda não existe lá
      # (orchestrator.py segue com _client = OpenAI(...) fixo); primeiro passo de habilitar troca de
      # provider sem mexer em código é confirmar que o valor certo está chegando.
      provider: operation_profile&.supervisor_provider,
      temperature: temperature,
      # BYOK (billing Fase 3): GAP achado em auditoria (13/08) — o orquestrador Python nunca recebia
      # NENHUMA chave por request, sempre a global fixa do .env dele; uma conta com custom_llm_api_key
      # ligado + chave própria configurada (ex.: conta #2) consumia a chave/cota da SCNET em silêncio
      # desde que o primeiro department dela foi pro Python. nil quando a conta não tem BYOK — o
      # orquestrador cai na chave global dele mesmo, comportamento IDÊNTICO a antes desta mudança.
      account_api_key: account_api_key
    }
  end

  # Mesma resolução que Ai::Gateway#maybe_byok_fallback (motor legado) já usa: só existe quando a
  # conta tem a feature custom_llm_api_key ligada E uma chave de verdade salva no Hub pro provider.
  def account_api_key
    Ai::ModelRouter.account_provider_key(@department.account_id, operation_profile&.supervisor_provider.presence || 'openai')
  end

  def image_url
    @message&.attachments&.to_a&.find { |a| a.file_type == 'image' }&.download_url.presence
  end

  # Scanned-PDF pages (CNH/RG/comprovante) rasterized by Ai::Workers::MediaProcessor, deferred here so
  # the SAME model turn that already has the step's context reads them — not a separate Rails-side
  # vision call with a generic, context-blind prompt (that's the actual root cause of a live bug: a
  # CNH's "1997" read as "1991"). Genuine text-layer PDFs never appear here — MediaProcessor only
  # defers pages it already decided (via #poor_extraction?) need vision to read at all.
  def document_image_urls
    Ai::Workers::MediaProcessor.pending_vision_images(@message)
  end

  # Direct photo first (if any), then document pages — order doesn't matter functionally, just keeps
  # the customer's own attachment first when both happen to be present in the same message.
  def image_urls
    ([image_url] + document_image_urls).compact
  end

  def operation_profile
    @agent.operation_profile
  end

  # Mesma tradução posição-do-slider -> temperatura real que Ai::ModelRouter já usa
  # (Ai::TemperatureMapper) — para o mesmo perfil, o Python deve receber a MESMA temperatura que o
  # caminho decide()/call_with_tools() já aplicaria.
  def temperature
    return nil unless operation_profile

    Ai::TemperatureMapper.resolve(operation_profile.supervisor_provider, operation_profile.temperature_position)
  end

  # Persona geral do agente + as regras de segurança/encerramento/transferência configuradas na conta
  # + a instrução da ETAPA ATUAL (âncora narrativa — não trava captura de dado nem avanço, só orienta
  # o que dizer agora) + como usar as tools de controle. Nunca a lista de etapas inteira como texto.
  def system_prompt
    lines = []
    # ESTÁTICO — byte-idêntico turno a turno pro MESMO agente+departamento (não depende de
    # ai_step_index, ai_collected_facts nem do conteúdo do turno atual). Tem que ficar TODO contíguo,
    # sem nenhum bloco dinâmico intercalado, pra habilitar o Prompt Caching automático da OpenAI
    # (documentado, sem custo de ativação): o cache é um match de PREFIXO — o primeiro byte que diverge
    # do turno anterior invalida o cache dali pra frente, então um bloco dinâmico no MEIO do prompt
    # (como estava antes) invalidava tudo que vinha depois dele, todo turno. Conteúdo de cada linha
    # inalterado — só a ORDEM mudou (achado 14/08, ticket 563, Frente 2 da compactação de prompt).
    #
    # Fixas e inegociáveis, ANTES de qualquer outra coisa: fecham lacunas achadas em teste ao vivo —
    # sugerir concorrentes, alucinar "médias de mercado" em vez do conhecimento real, "fingir" que
    # chamou registrar_* sem chamar de verdade, inventar situações que não existem, e transferir sem
    # motivo pulando o fluxo de etapas. Múltiplas mensagens por turno (modo identify_as="human") tem
    # instrução PRÓPRIA logo abaixo (#identify_as_instruction) — achado ao vivo 13/08: por um tempo
    # esteve ausente aqui (ver comentário do método), regressão já corrigida.
    lines << identity_instruction
    lines << identify_as_instruction
    lines << market_average_guardrail
    lines << no_fabrication_instruction
    lines << transfer_discipline_instruction
    lines << tool_error_instruction
    lines << gradual_conversation_instruction
    lines << "Você é #{@agent.assistant_name.presence || @agent.name}."
    lines << @agent.base_prompt if @agent.base_prompt.present?
    lines << "Personalidade: #{@agent.assistant_personality}." if @agent.assistant_personality.present?
    lines << "Responda no idioma #{@agent.assistant_language}." if @agent.assistant_language.present?
    lines << "Regras de segurança (nunca viole): #{@agent.guardrails}." if @agent.guardrails.present?
    lines << "Departamento: #{@department.name}. Objetivo: #{@department.objetivo}."
    lines << "Transfira para humano quando: #{transfer_when_text}." if transfer_when_text.present?
    lines << "Encerre quando: #{close_when_text}." if close_when_text.present?
    lines << "Mensagem de encerramento sugerida: #{close_message}." if close_message.present?
    lines << structured_output_instruction

    # DINÂMICO — muda a cada turno (documento anexado neste turno, fatos acumulados, ai_step_index
    # avança). Fica no FINAL, contíguo, nunca antes do bloco estático acima.
    lines << document_extraction_instruction if image_urls.present?
    lines << collected_facts_block if collected_facts_block.present?
    lines << "ETAPA ATUAL:\n#{current_step_instructions}" if current_step_instructions.present?
    lines << "PRÓXIMA ETAPA (só contexto — NÃO é a atual; NÃO pule pra ela, NÃO peça o dado dela, e " \
             "NÃO execute nenhuma ação ou ferramenta que ela descreva (ex.: transferir_humano, " \
             "encerrar_atendimento) antes da hora — só a etapa ATUAL manda no que fazer AGORA, mesmo " \
             "que você já tenha todos os dados que a próxima etapa pediria; mas se o cliente ADIANTAR " \
             "um DADO dela por conta própria, capture normalmente — ver REGRAS DE FOCO E VALIDAÇÃO DA " \
             "COLETA abaixo; use isso só pra conduzir a conversa com continuidade, sem soar como se não " \
             "soubesse o que vem a seguir):\n#{next_step_instructions}" \
      if next_step_instructions.present?
    lines << step_extraction_instruction if step_extraction_instruction.present?
    lines << data_validation_instruction if data_validation_instruction.present?
    lines << force_handoff_instruction if @force_handoff_notice
    lines.join("\n")
  end

  # Texto do pedido, com UM ajuste: a frase original citava "a ferramenta de busca (file_search)" —
  # mas não existe vector store nenhum aqui (ver comentário em #payload), então instruir a IA a chamar
  # uma tool que não existe seria pior que o problema original. Aponta pra tool real #knowledge_tool
  # (consultar_conhecimento) em vez de um bloco fixo — a IA CHAMA a ferramenta antes de responder,
  # não lê um texto que pode nem ter sido injetado. #knowledge_tool só entra em #tools_schema quando o
  # department TEM conhecimento cadastrado (#has_knowledge?) — sem isso, citar a ferramenta aqui
  # instruiria a IA a chamar algo que nem está na lista, então a frase se adapta ao mesmo booleano.
  def identity_instruction
    base = 'IDENTIDADE: Você é um atendente de IA DA PRÓPRIA EMPRESA. A empresa para quem você trabalha É a ' \
      'provedora do serviço. É ESTRITAMENTE PROIBIDO sugerir que o cliente procure outras empresas, ' \
      'operadoras ou provedores. '
    base + if has_knowledge?
             'Se o cliente quiser preços, condições ou tiver dúvidas, use a ferramenta ' \
               '"consultar_conhecimento" antes de responder — nunca invente o que ela não retornar.'
           else
             'Se o cliente quiser preços, condições ou tiver dúvidas que você não tenha certeza ' \
               'absoluta, diga que vai verificar — nunca invente.'
           end
  end

  # PORTADO do Ai::PromptCompiler legado (identity_lines) — regressão achada ao vivo (13/08, ticket
  # Maya v5.0): a migração pro Python NUNCA trouxe esta instrução. O mecanismo de split continuou
  # 100% intacto no lado Ruby (Ai::ActionDispatcher#deliver/#split_parts, as_human: @agent.identify_as
  # == 'human', ver Ai::Gateway#action_dispatcher) — mas sem isto, nada dizia ao MODELO para produzir
  # "\n\n" em mensagem_para_cliente, então split_parts nunca tinha o que quebrar (devolve o texto
  # original quando não há linha em branco). Bug latente desde que este arquivo existe (10/08); só
  # ficou visível quando o department em questão migrou pro caminho Python (rollout de hoje, 13/08) —
  # não é regressão da eliminação do motor legado em si, é uma lacuna que a eliminação expôs pra
  # TODOS os departments de uma vez, em vez de só os que já tinham python_orchestrator opt-in.
  def identify_as_instruction
    if @agent.identify_as == 'ai'
      'Você é um assistente virtual (IA) e pode assumir isso se perguntarem.'
    else
      'Aja como um atendente humano da equipe. Não diga que é uma inteligência artificial. Quando a ' \
        'resposta tiver mais de uma ideia ou ficar longa, escreva como uma pessoa real digitando: separe ' \
        'em mensagens curtas com uma LINHA EM BRANCO entre elas (dois \n) no campo "mensagem_para_cliente". ' \
        'Se for algo curto, responda em uma mensagem só, sem quebrar à força.'
    end
  end

  # Reforço explícito contra "médias de mercado": IA alucinava preço/regra plausível-mas-inventado
  # em vez de usar o conhecimento real, e só se corrigia quando o cliente reclamava — reforça a
  # mesma proibição de #identity_instruction com outra frase, mirando especificamente esse padrão.
  # Mesmo ajuste condicional a #has_knowledge? que #identity_instruction — ver comentário lá.
  def market_average_guardrail
    base = 'Você é um atendente DA EMPRESA. Nunca cite concorrentes, médias de mercado ou valores '
    base + if has_knowledge?
             'que não venham da ferramenta "consultar_conhecimento".'
           else
             'que você não tenha certeza absoluta — nunca invente.'
           end
  end

  # Achado em teste ao vivo: a IA inventava situações plausíveis mas inexistentes ("instabilidade no
  # sistema", "link seguro", "formulário externo") pra preencher lacunas em vez de admitir que não sabe.
  def no_fabrication_instruction
    'É PROIBIDO inventar situações, recursos ou funcionalidades que não existem (ex: "instabilidade no ' \
      'sistema", "link seguro", "formulário externo"). Se algo não estiver disponível, diga simplesmente ' \
      'que vai encaminhar para um especialista.'
  end

  # Achado em teste ao vivo: a IA transferia pra humano "achando" que devia, pulando o fluxo de etapas
  # inteiro. Limite NARRATIVO unificado com #data_validation_instruction (1 tentativa de esclarecimento
  # por dado, não mais um número fixo de mensagens independente) — antes este método dizia "5 mensagens"
  # enquanto #data_validation_instruction já dizia "1 vez"; dois limiares divergentes pro MESMO gatilho
  # de ação crítica. O teto REAL enforçado no backend (Ai::Gateway#step_turns_exceeded?,
  # transfer_rules['stuck_handoff_turns'], default 10 — ver force_handoff_instruction) continua sendo um
  # backstop separado de propósito (turnos totais da etapa, não tentativas por dado) — não precisa bater
  # com este número.
  def transfer_discipline_instruction
    'Transfira para humano quando: o cliente pedir explicitamente para falar com uma pessoa; ' \
      'demonstrar frustração clara (reclamar, repetir a mesma dúvida, pedir pra falar com pessoa) — ' \
      'nesse caso transfira IMEDIATAMENTE, mesmo sem ter tentado esclarecer antes; ou o cliente não ' \
      'conseguir fornecer um dado válido mesmo depois de 1 pedido de esclarecimento — não exija mais de ' \
      '1 nova tentativa por dado antes de transferir, insistir além disso cansa o cliente. NUNCA ' \
      'transfira só porque "achou" que deve. Siga o fluxo de etapas até o final.'
  end

  # Generalização do fix de consultar_conhecimento (knowledge_timeout/knowledge_search_failed) pra
  # QUALQUER ferramenta real: achado ao vivo (conv 556, consultar_periodos) — quando uma ferramenta
  # falhava de verdade (erro técnico, não falta de dado), o modelo não tinha NENHUMA instrução de como
  # reagir e travava enrolando o cliente em 4 respostas vagas, sem nunca avisar do problema nem
  # chamar de novo. orchestrator.py agora normaliza toda falha real de tool em {"error": true,
  # "message": "..."} (ver _normalize_tool_result) — esta instrução ensina o modelo a reconhecer esse
  # sinal específico e agir.
  def tool_error_instruction
    'Se o resultado de QUALQUER ferramenta vier com "error": true, isso é uma falha TÉCNICA real da ' \
      'ferramenta (não falta de dado do cliente) — avise o cliente que teve um problema técnico agora ' \
      'e ofereça transferir para um atendente humano. NUNCA invente uma resposta no lugar do resultado ' \
      'que faltou, e NUNCA chame a mesma ferramenta de novo no mesmo turno esperando um resultado ' \
      'diferente.'
  end

  # Achado em teste ao vivo (esclarecido pelo usuário: NÃO é sobre várias mensagens por turno — isso é
  # o modo identify_as="human" funcionando como esperado): a IA perguntava várias etapas de uma vez
  # (nome + endereço + CPF + telefone na mesma mensagem) em vez de conduzir uma pergunta por vez, mesmo
  # com TODAS as tools "registrar_*" disponíveis simultaneamente (fluxo agentic, sem gate por etapa).
  # EXCEÇÃO explícita (antes ausente — a regra era uma proibição absoluta, tom tratado com rigidez de
  # ação): dado front-loaded pelo PRÓPRIO cliente tem que ser capturado, nunca ignorado só pra manter a
  # cadência "uma pergunta por vez" — cadência é tom, captura de dado é fato, não podem competir.
  def gradual_conversation_instruction
    'Prefira pedir os dados da etapa atual UM DE CADA VEZ, de forma natural e conversacional — mesmo ' \
      'que várias ferramentas "registrar_*" estejam disponíveis ao mesmo tempo, não liste várias ' \
      'perguntas na mesma mensagem por iniciativa própria. EXCEÇÃO: se o cliente fornecer ' \
      'espontaneamente mais de um dado na mesma mensagem — mesmo sem você ter perguntado — registre ' \
      'TODOS os dados válidos fornecidos naquela mensagem; nunca finja que não viu um dado só para ' \
      'manter o ritmo de "uma pergunta por vez".'
  end

  # Achado ao vivo: a IA leu uma CNH em PDF e alucinou o ano (1997 virou 1991), além de salvar dados
  # que a etapa nem tinha pedido (data de nascimento, RG). A leitura em si é DESEJADA (o usuário foi
  # explícito: não proibir) — o problema é confiar cegamente num número que não deu pra ler direito.
  # Documentos escaneados (imagem direta OU PDF via Ai::PythonOrchestratorClient#document_image_urls)
  # chegam como pixels crus NESTE MESMO turno agora (não mais uma legenda de uma chamada separada e
  # sem contexto) — a regra de "não chutar" vale exatamente porque é a IA MESMA, com o contexto da
  # etapa, quem está olhando a imagem.
  #
  # Chamado só quando #image_urls.present? (achado 14/08): este bloco ia pro system_prompt em TODO
  # turno, mesmo nos que são só texto puro — a maioria. Gate determinístico em Ruby (mesmo cálculo que
  # já decide o que entra em "image_urls" no payload) em vez de julgamento do modelo: sem tool nova,
  # sem depender de decisão cruzada entre etapas.
  def document_extraction_instruction
    "REGRA DE EXTRAÇÃO DE DOCUMENTOS (PDFs e Imagens):\n" \
      "- Quando o cliente enviar um documento (CNH, RG, comprovante), analise a imagem cuidadosamente " \
      "para extrair os dados solicitados pela etapa atual.\n" \
      "- Extraia os dados que a etapa atual pede. Olhe o documento, encontre o dado e inclua em " \
      "\"dados_coletados\".\n" \
      '- Validação de imagem: se a imagem estiver borrada ou você não tiver 100% de certeza sobre um ' \
      'número (ex.: não sabe se é 1991 ou 1997), NÃO chute. Só inclua o dado em "dados_coletados" se ' \
      'tiver certeza visual. Se não tiver certeza, não preencha esse dado e diga ao cliente algo como: ' \
      "\"Não consegui ler o [dado] com clareza na foto. Pode me confirmar qual é?\"\n" \
      '- Não invente nem infira dados que o documento não pediu explicitamente e a etapa não pede — ' \
      'extraia SÓ o que a etapa atual está pedindo, mesmo que o documento mostre outros campos.'
  end

  # Bug real ao vivo: o Rails salvava certinho em ai_collected_facts (Ai::StateManager#persist_attributes,
  # via os "registrar_*"/"salvar_memoria_ia" do Api::Internal::AiExecuteToolController), mas o
  # system_prompt nunca injetava esse resumo de volta — a IA "esquecia" o que o próprio cliente já tinha
  # informado, porque cada turno só recebia o histórico bruto (via previous_response_id), sem um resumo
  # explícito do que JÁ está salvo. Espelha o antigo "Dados já coletados" do caminho legado
  # (Ai::PromptCompiler — hoje um bloco mais elaborado, ESTADO DA COLETA, mas o princípio é o mesmo).
  def collected_facts_block
    facts = @conversation.additional_attributes&.dig('ai_collected_facts')
    return nil if facts.blank?

    lines = ['DADOS JÁ COLETADOS NESTA CONVERSA (Não pergunte nada disso de novo, já está salvo no sistema):']
    # Ai::StepSlot.display: mesmo mapeamento do caminho legado — nunca vaza o token interno de recusa
    # (Ai::StepSlot::ABSENT, '__sem_valor__') cru pro modelo, caso esta conversa também tenha dado
    # gravado pelo motor legado (department pode ter alternado o flag python_orchestrator no meio do
    # atendimento — ai_collected_facts vive na conversation, não é exclusivo de um motor).
    facts.each { |key, value| lines << "- #{key}: #{Ai::StepSlot.display(value)}" }
    lines.join("\n")
  end

  # Objetivo/Regras/Fala sugerida (padrão estruturado) quando a etapa já foi migrada; texto livre de
  # step['instructions'] (fallback) para etapas antigas — Ai::StepInstructionText decide qual dos dois.
  # Sanitizado (ver #sanitize_stale_tool_calls) SÓ aqui, não no módulo compartilhado — o motor legado
  # (Ai::PromptCompiler) não usa este método.
  def current_step_instructions
    sanitize_stale_tool_calls(Ai::StepInstructionText.render(current_step))
  end

  # Pedido do usuário (mesmo padrão achado no fluxo n8n Maya v4.0: manda objetivo + texto da PRÓXIMA
  # etapa junto, não só a atual) — dá à IA visão de onde a conversa vai em seguida, sem mudar QUEM
  # decide o avanço (isso continua sendo só avancar_etapa; ver ETAPA ATUAL acima, que segue a única
  # âncora que trava o quê fazer AGORA). nil na última etapa ou sem playbook.
  def next_step_instructions
    sanitize_stale_tool_calls(Ai::StepInstructionText.render(next_step))
  end

  # Mesma fonte que #current_step usa (Ai::StateManager#next_step — já existia pro look-ahead de
  # conhecimento do motor legado, reaproveitada aqui). Leitura PURA, não avança nada.
  def next_step
    @next_step ||= state_manager.next_step(@department)
  end

  # Bug URGENTE ao vivo: etapas escritas (ou geradas pelo Ai::PromptAssistant) ANTES da migração pra
  # Structured Outputs têm texto tipo "chame a ferramenta registrar_nome_cliente"/"chame a ferramenta
  # avancar_etapa" — tools que orchestrator.py não oferece MAIS à OpenAI (filtradas, ver
  # _is_superseded_tool). A IA lia a instrução, procurava a tool entre as oferecidas, não achava, e
  # DESISTIA — encerrava o atendimento prematuramente. Ai::PromptAssistant::Prompts para de GERAR essa
  # frase daqui pra frente, mas isso não corrige texto JÁ salvo no banco — este método reescreve (não
  # apaga) as 5 referências reservadas de controle/captura pelo EQUIVALENTE no contrato JSON, mantendo
  # o resto da frase (ex.: o critério "assim que tiver capturado X e Y" continua, só a AÇÃO citada
  # muda). Referência a uma tool REAL (ex.: "consulte a ferramenta consultar_periodos") nunca bate
  # nestes 5 nomes reservados — Ai::StepCaptureTool::PREFIX ('registrar_') e as 4 constantes de
  # controle nunca colidem com o nome de um Ai::Tool admin-configurado, então não há risco de mexer
  # em instrução de tool real por engano.
  def sanitize_stale_tool_calls(text)
    return text if text.blank?

    sanitized = text.dup
    sanitized.gsub!(/chame\s+(?:imediatamente\s+)?a\s+(?:ferramenta|tool)\s+['"]?registrar_\w+['"]?\s*(?:correspondente)?/i,
                     'inclua esse dado em "dados_coletados" no seu JSON de resposta')
    sanitized.gsub!(/chame\s+(?:imediatamente\s+)?a\s+(?:ferramenta|tool)\s+['"]?avancar_etapa['"]?/i,
                     'defina "avancar_etapa": true no seu JSON de resposta')
    sanitized.gsub!(/chame\s+(?:imediatamente\s+)?a\s+(?:ferramenta|tool)\s+['"]?salvar_memoria_ia['"]?/i,
                     'inclua esse dado em "dados_coletados" no seu JSON de resposta')
    sanitized.gsub!(/chame\s+(?:imediatamente\s+)?a\s+(?:ferramenta|tool)\s+['"]?conversation[._]transfer['"]?/i,
                     'defina "transferir_humano": true no seu JSON de resposta')
    sanitized.gsub!(/chame\s+(?:imediatamente\s+)?a\s+(?:ferramenta|tool)\s+['"]?conversation[._]resolve['"]?/i,
                     'defina "encerrar_atendimento": true no seu JSON de resposta')
    sanitized
  end

  # Achado pelo usuário: o admin escreve SÓ "Objetivo"/"Regras" em linguagem natural na tela da etapa
  # (AiStepForm.vue) — "JSON"/"dados_coletados" nunca deveriam aparecer ali. Esta regra é montada AQUI
  # pelo Rails, nunca digitada pelo admin, a partir do "Dado que esta etapa coleta" (o Select que grava
  # collect.attribute — MESMA fonte, Ai::StepSlot.attribute, que o design antigo de function-calling
  # usava pra nomear a tool "registrar_<attribute>", Ai::StepCaptureTool). Complementa (não substitui)
  # #structured_output_instruction: aquela é a regra GERAL do contrato JSON; esta nomeia a chave exata
  # que importa NESTA etapa, pra IA não "escolher" um nome de chave por conta própria. nil numa etapa
  # informativa (sem collect) — não força a IA a inventar uma chave que não existe.
  def step_extraction_instruction
    attribute = Ai::StepSlot.attribute(current_step)
    return nil if attribute.blank?

    "REGRA DE EXTRAÇÃO JSON: Nesta etapa, você deve extrair o dado referente a '#{attribute}' " \
      "(#{step_slot_metadata_text}). Assim que o cliente informar isso, você DEVE adicionar um item na " \
      "lista \"dados_coletados\" no seu JSON de resposta com \"chave\": \"#{attribute}\" e o valor " \
      'extraído.'
  end

  # Tipo/opções/obrigatoriedade do slot da etapa ATUAL, pro contexto de #data_validation_instruction
  # ter algo real pra validar contra — sem isso a IA só teria o NOME do atributo, sem saber se é CPF,
  # telefone, uma lista fechada de opções, etc. tools_schema TINHA essa info (o input_schema de
  # "registrar_<attribute>"), mas essa tool é filtrada antes de chegar à OpenAI (orchestrator.py) — só
  # sobrava o nome da chave. Ai::StepSlot é a MESMA fonte que gerava aquele input_schema.
  def step_slot_metadata_text
    type = Ai::StepSlot.type(current_step)
    options = Ai::StepSlot.options(current_step)
    required = !Ai::StepSlot.optional?(current_step)

    parts = ["tipo: #{type}"]
    parts << "opções válidas: #{options.join(', ')}" if options.present?
    parts << (required ? 'OBRIGATÓRIO' : 'opcional')
    parts.join(', ')
  end

  # Pedido do usuário: apertar o foco da coleta (só o dado da etapa atual, com exceção clara pra
  # front-loading) + validar formato por tipo antes de gravar + escalar (esclarecer 1x, depois
  # transferir/aceitar vazio) quando o valor não bate ou não vem. Convive com — não substitui —
  # #structured_output_instruction (a regra GERAL "grave QUALQUER dado que o cliente der" continua
  # valendo; esta é mais específica: QUAL dado follow essa etapa espera e QUANDO ele é válido pra
  # gravar). nil numa etapa informativa (sem collect) — nada pra validar sem um slot declarado.
  def data_validation_instruction
    attribute = Ai::StepSlot.attribute(current_step)
    return nil if attribute.blank?

    "REGRAS DE FOCO E VALIDAÇÃO DA COLETA (além da regra geral de \"dados_coletados\" acima):\n" \
      "- Extraia para \"dados_coletados\" APENAS o dado que a etapa atual está pedindo explicitamente " \
      "(\"#{attribute}\", ver REGRA DE EXTRAÇÃO JSON). Se o cliente disser algo avulso, fora do foco " \
      "da etapa e que não é um dado real de nenhuma etapa, IGNORE — não crie uma chave pra isso.\n" \
      "- EXCEÇÃO: se o cliente adiantar espontaneamente um dado de uma etapa FUTURA, de forma clara e " \
      "válida, capture também em \"dados_coletados\" (mesma lógica: chave = nome do dado).\n" \
      "- Grave sempre o VALOR extraído, nunca a frase inteira do cliente (ex.: cliente disse \"meu " \
      "nome é Jaqueline\" → grave \"Jaqueline\", não a frase completa).\n" \
      "- Antes de gravar, confira se o valor bate com o TIPO e as OPÇÕES da etapa atual (indicados na " \
      "REGRA DE EXTRAÇÃO JSON acima). Referência por tipo: CPF = 11 dígitos numéricos; telefone = " \
      "mínimo 8 dígitos numéricos; e-mail = contém @ e domínio válido; número = só dígitos; escolha = " \
      "valor dentro das opções listadas; anexo = só se um arquivo foi realmente enviado; texto = " \
      "qualquer valor com conteúdo semântico real (não vazio, não só pontuação).\n" \
      "- Se o valor NÃO bater com o tipo: peça correção UMA vez, de forma isolada e direta — não repita " \
      "a etapa inteira, só aponte o que falta corrigir. Se o cliente não corrigir: " \
      "campo OBRIGATÓRIO → defina \"transferir_humano\": true (preencha \"handoff_summary\"); campo " \
      "opcional → não grave nada nessa chave e siga em frente.\n" \
      "- Se o cliente simplesmente NÃO fornecer o dado pedido: campo OBRIGATÓRIO → peça UMA vez; se " \
      "ele ignorar de novo, defina \"transferir_humano\": true; campo opcional → mande " \
      '"dados_coletados" vazio ([]) e defina "avancar_etapa": true.'
  end

  # Mesma fonte e formatação que Ai::PromptCompiler#step_lines/compile já usa para transfer_when/
  # close_when (Ai::Playbook, não Ai::Department) — mesmo texto que o caminho legado mostraria.
  def transfer_when_text
    Array(@department.playbook&.transfer_when).join('; ').presence
  end

  def close_when_text
    Array(@department.playbook&.close_when).join('; ').presence
  end

  def close_message
    @department.close_rules.to_h['message'].presence
  end

  # Substitui a antiga instrução de function-calling (tool_usage_instruction/
  # must_call_capture_tools_instruction/no_confirmation_loop_instruction — removidas): orchestrator.py
  # não oferece mais "registrar_*"/"avancar_etapa"/"salvar_memoria_ia"/"continuar_conversa"/
  # conversation.resolve/conversation.transfer como tools à OpenAI (Ai::PythonOrchestratorClient ainda
  # os calcula em #tools_schema — inofensivo, o Python os filtra antes de montar a lista de tools).
  # Structured Outputs (response.text.format=json_object, orchestrator.py) força CADA resposta a ser
  # este objeto JSON; o Python decide sozinho quando chamar os webhooks de controle, a partir do que
  # está NO JSON — dizer que salvou sem preencher "dados_coletados" deixou de ser possível, porque
  # "dados_coletados" É o salvamento, não uma alegação em texto que dependia da IA lembrar de chamar
  # uma tool à parte.
  # Contrato reforçado por json_schema ESTRITO no lado Python (STRUCTURED_REPLY_SCHEMA, orchestrator.py)
  # — a OpenAI VALIDA a resposta contra o schema antes de devolver, não é mais só o texto aqui embaixo
  # que garante a forma. dados_coletados virou LISTA de {chave, valor} (não objeto de chave livre) por
  # exigência do strict mode (additionalProperties:false em todo nível não aceita chave arbitrária) —
  # continua aceitando VÁRIOS dados no mesmo turno, um item por dado.
  def structured_output_instruction
    "FORMATO DE RESPOSTA OBRIGATÓRIO: Toda resposta sua DEVE ser um único objeto JSON válido, e SOMENTE " \
      "o JSON — sem texto antes ou depois, sem markdown, no formato exato:\n" \
      "{\n" \
      "  \"mensagem_para_cliente\": \"o texto que será enviado ao cliente no WhatsApp\",\n" \
      "  \"dados_coletados\": [{\"chave\": \"nome_do_dado\", \"valor\": \"valor_extraido\"}],\n" \
      "  \"avancar_etapa\": true ou false,\n" \
      "  \"transferir_humano\": true ou false,\n" \
      "  \"encerrar_atendimento\": true ou false,\n" \
      "  \"handoff_summary\": \"resumo do atendimento — obrigatório quando transferir_humano for true\"\n" \
      "}\n" \
      "REGRAS:\n" \
      "- Se o cliente forneceu QUALQUER dado (nome, endereço, CPF, telefone, email, preferência, etc.), " \
      "adicione UM ITEM em \"dados_coletados\" por dado — cada item é {\"chave\": nome descritivo do " \
      "dado, \"valor\": o que o cliente disse}; pode mandar VÁRIOS itens no mesmo turno se o cliente deu " \
      "vários dados de uma vez. Chamar de novo com um valor diferente pra MESMA chave ATUALIZA o dado, " \
      "não duplica. Se não forneceu nada novo neste turno, \"dados_coletados\" DEVE ser a lista vazia [].\n" \
      "- É ESTRITAMENTE PROIBIDO dizer em \"mensagem_para_cliente\" que recebeu/anotou um dado sem, na " \
      "MESMA resposta, colocar esse dado em \"dados_coletados\" — o dado só existe no sistema se " \
      "estiver ali; se você disser que anotou sem preencher \"dados_coletados\", o dado será PERDIDO.\n" \
      "- Assim que o cliente responder o que a etapa atual pede, NÃO peça confirmação ('é isso mesmo?', " \
      "'posso confirmar?') — registre o dado em \"dados_coletados\" E marque \"avancar_etapa\": true na " \
      "MESMA resposta, sem inserir um turno extra de confirmação.\n" \
      "- \"avancar_etapa\": true quando a etapa atual estiver concluída, ou quando o cliente recusar um " \
      "dado opcional (avance com empatia, sem forçar); caso contrário, false.\n" \
      "- \"transferir_humano\": true SOMENTE quando precisar transferir para um atendente humano; nesse " \
      "caso preencha \"handoff_summary\" com o que já foi conseguido (ex: \"Cliente já forneceu nome e " \
      "cidade, falta CPF\") e o motivo da transferência.\n" \
      "- É ESTRITAMENTE PROIBIDO escrever em \"mensagem_para_cliente\" qualquer variação de \"vou " \
      "transferir\", \"chamar um especialista\", \"encaminhar para atendente\" ou similar sem, na MESMA " \
      "resposta, marcar \"transferir_humano\": true e preencher \"handoff_summary\" — se você disser " \
      "que vai transferir sem marcar o campo, a transferência NÃO acontece e o cliente fica sem " \
      "atendimento.\n" \
      "- \"encerrar_atendimento\": true SOMENTE quando as condições de encerramento configuradas abaixo " \
      "forem atendidas.\n" \
      "- É ESTRITAMENTE PROIBIDO escrever em \"mensagem_para_cliente\" qualquer variação de " \
      "\"atendimento encerrado\", \"até logo\", \"finalizando\" ou similar sem marcar " \
      "\"encerrar_atendimento\": true na MESMA resposta.\n" \
      'Nunca responda fora deste formato JSON, mesmo que só queira cumprimentar ou tirar uma dúvida — ' \
      'nesse caso "dados_coletados" fica [] e os demais booleanos ficam false.'
  end

  def force_handoff_instruction
    'LIMITE DE TENTATIVAS ATINGIDO NESTA ETAPA. Responda AGORA com "transferir_humano": true e ' \
      '"handoff_summary" preenchido, mesmo que a etapa não tenha concluído.'
  end

  # Tools reais do department (webhooks/capabilities/integrations) + UMA "registrar_*" por atributo
  # declarado em QUALQUER etapa do playbook (Ai::StepCaptureTool, todas de uma vez — fluxo agentic,
  # sem gate por etapa ativa) + as tools de controle (continuar/memória genérica/avançar/encerrar/
  # transferir). Structured Outputs (orchestrator.py) substituiu o mecanismo de controle por
  # function-calling — este método continua gerando o catálogo completo (histórico + o formato que
  # Api::Internal::AiExecuteToolController já reconhece), mas orchestrator.py filtra "registrar_*" e as
  # 5 tools de controle antes de montar a lista que vai pra OpenAI; só tools REAIS chegam lá. Nomes
  # SANITIZADOS (Ai::ToolNameSanitizer) — a OpenAI rejeita qualquer coisa fora de [a-zA-Z0-9_-] (400
  # "does not match pattern"), e as chaves do Ai::CapabilityRegistry são pontuadas (conversation.resolve,
  # conversation.add_label, contact.update_attributes...) por convenção. Api::Internal::
  # AiExecuteToolController reverte isso batendo o nome recebido contra este MESMO catálogo
  # (department.tools.active + as 2 constantes de controle), não adivinhando "_" == ".".
  def tools_schema
    real_names = real_tools.map { |t| t[:name] }
    synthesized = step_capture_tools + control_tools + knowledge_tools
    real_tools + synthesized.reject { |t| real_names.include?(t[:name]) }
  end

  def real_tools
    @real_tools ||= @department.tools.active.map do |tool|
      { name: Ai::ToolNameSanitizer.sanitize(tool.name), description: tool.description, input_schema: tool.input_schema }
    end
  end

  # Catálogo COMPLETO — não só o que a etapa atual (ou qualquer etapa) declara via collect. Achado ao
  # vivo: uma etapa cuja instrução em texto livre pede "CPF, email e telefone" só tinha 1 desses no
  # dropdown collect, então a IA recebia a instrução mas não tinha o "botão" (a tool) pros outros 2 —
  # alucinava "problema técnico". known_slot_keys já é a união certa (Ai::StateManager: steps ∪
  # lead_variables ∪ CustomAttributeDefinition da account) — mesma fonte que o caminho legado usa pro
  # contrato de asked_slot, reaproveitada aqui em vez de duplicada.
  def step_capture_tools
    @step_capture_tools ||= Ai::StepCaptureTool.schemas_for(@department.playbook, known_attribute_keys)
  end

  def known_attribute_keys
    state_manager.known_slot_keys(@department)
  end

  def state_manager
    @state_manager ||= Ai::StateManager.new(conversation: @conversation, agent: @agent)
  end

  def sanitized_resolve_tool
    Ai::ToolNameSanitizer.sanitize(RESOLVE_TOOL)
  end

  def sanitized_transfer_tool
    Ai::ToolNameSanitizer.sanitize(TRANSFER_TOOL)
  end

  def sanitized_continue_tool
    Ai::ToolNameSanitizer.sanitize(CONTINUE_TOOL)
  end

  # Sempre disponíveis (não dependem de configuração por department) — o modelo controla o avanço da
  # etapa e pode encerrar/transferir a qualquer momento, seguindo as regras do system_prompt acima.
  # ADVANCE_STEP_TOOL já é seguro (sem pontuação) — sanitizar é no-op, mas passa pela MESMA função por
  # uniformidade (nunca dois caminhos diferentes decidindo "isso já está seguro ou não").
  def control_tools
    [
      { name: sanitized_continue_tool,
        description: 'Use esta ferramenta APENAS quando você NÃO tem nenhum dado novo do cliente pra ' \
                     'salvar — fazer uma pergunta, cumprimentar, responder uma dúvida. NUNCA use esta ' \
                     'ferramenta se o cliente ACABOU de fornecer um dado (nome, CPF, endereço, etc.): ' \
                     'nesse caso chame "registrar_*" ou "salvar_memoria_ia" primeiro. Chamar esta ' \
                     'ferramenta e depois dizer "recebi"/"anotei" em texto, sem ter salvo nada, PERDE o ' \
                     'dado do cliente.',
        input_schema: { type: 'object', properties: {} } },
      { name: Ai::ToolNameSanitizer.sanitize(MEMORY_TOOL),
        description: 'Salva qualquer informação relevante que o cliente fornecer e que NÃO tenha uma ' \
                     'ferramenta "registrar_*" específica — memória de contexto (não espelha para ' \
                     'painel/CRM, só fica disponível para a própria IA não perguntar de novo). Substitua ' \
                     '"chave" pelo nome do dado (ex: nome, cpf, plano) e "valor" pelo conteúdo informado.',
        input_schema: {
          type: 'object',
          properties: {
            'chave' => { type: 'string', description: 'Nome do dado (ex.: "nome_do_animal_de_estimacao").' },
            'valor' => { type: 'string', description: 'O que o cliente informou.' }
          },
          required: %w[chave valor]
        } },
      { name: Ai::ToolNameSanitizer.sanitize(ADVANCE_STEP_TOOL),
        description: 'Avança para a próxima etapa do atendimento. Use quando a etapa atual estiver ' \
                     'concluída, ou quando o cliente recusar um dado opcional — nunca force, avance com empatia.',
        input_schema: { type: 'object', properties: {} } },
      { name: sanitized_resolve_tool,
        description: 'Encerra o atendimento (marca a conversa como resolvida) quando as condições de ' \
                     'encerramento configuradas forem atendidas.',
        input_schema: { type: 'object', properties: {} } },
      { name: sanitized_transfer_tool,
        description: 'Transfere o atendimento para um humano quando as condições de transferência ' \
                     'configuradas forem atendidas, ou quando instruído a transferir imediatamente. ' \
                     'SEMPRE preencha handoff_summary: um resumo do que já foi conseguido e o motivo da transferência.',
        input_schema: {
          type: 'object',
          properties: {
            'handoff_summary' => { type: 'string',
                                    description: 'Resumo do que já foi conseguido (ex.: "Cliente já forneceu ' \
                                                 'nome e cidade, falta CPF") e o motivo da transferência.' }
          },
          required: ['handoff_summary']
        } }
    ]
  end

  # DIFERENTE dos 5 tools acima: aquelas são "control_tools" — orchestrator.py FILTRA os nomes em
  # _CONTROL_TOOL_NAMES antes de montar a lista pra OpenAI (Python decide dispará-las a partir do JSON
  # já parseado, depois que o turno terminou). "consultar_conhecimento" tem que ser uma function tool
  # DE VERDADE, oferecida à OpenAI e chamada NO MEIO do turno (mesmo loop de tool-call que já atende
  # tools reais tipo consultar_periodos) — o resultado da busca precisa voltar pra IA ANTES dela montar
  # a resposta final, não depois. Por isso este método fica separado de #control_tools. Sem query
  # pré-configurada nem filtro de tipo — a IA formula a pergunta e decide quando chamar, a partir do
  # objetivo da etapa + o que o cliente perguntou.
  #
  # Condicional a #has_knowledge? (diferente das control_tools, que são sempre oferecidas independente
  # de configuração): oferecer a ferramenta sem NENHUM conhecimento cadastrado só ensina a IA a chamar
  # algo que sempre volta vazio — gasta uma rodada de tool-call à toa e engorda tools_schema à toa.
  # #identity_instruction/#market_average_guardrail usam o MESMO booleano pra não citar a ferramenta
  # quando ela não está na lista.
  def knowledge_tools
    has_knowledge? ? [knowledge_tool] : []
  end

  # Existe pelo menos uma Ai::KnowledgeSource ativa (do department ou compartilhada da conta) com
  # conteúdo já indexado (Ai::KnowledgeChunk) — mesmo escopo que Ai::KnowledgeRetriever usa pra
  # buscar, reaproveitado aqui pra não divergir. Uma fonte cadastrada mas ainda sem chunks (ingest
  # ainda não rodou) conta como "sem conhecimento" — a ferramenta só ajuda quando há o que buscar.
  def has_knowledge?
    return @has_knowledge if defined?(@has_knowledge)

    source_ids = Ai::KnowledgeRetriever.source_ids_for(@department.account_id, @department.id, nil)
    @has_knowledge = source_ids.present? && Ai::KnowledgeChunk.where(ai_knowledge_source_id: source_ids).exists?
  end

  # Descrição genérica (não amarrada a um segmento específico como internet/telecom) — qualquer
  # negócio com uma base de conhecimento cadastrada usa a mesma ferramenta e o mesmo texto.
  def knowledge_tool
    { name: KNOWLEDGE_TOOL,
      description: 'Busca na base de conhecimento oficial da empresa (preços, condições, regras, ' \
                   'políticas). Use sempre que a pergunta do cliente depender de informação real da ' \
                   'empresa e você não tiver certeza absoluta. Se não retornar nada relevante, diga ' \
                   'que vai verificar ou transfira — nunca invente.',
      input_schema: {
        type: 'object',
        properties: {
          'pergunta' => { type: 'string',
                          description: 'A pergunta ou termo de busca, na linguagem do cliente.' }
        },
        required: ['pergunta']
      } }
  end

  # Leitura PURA do índice server-tracked (Ai::StateManager#current_step) — não roda track_step, não
  # avança nada; só lê o mesmo ai_step_index que o caminho legado também lê. Quem avança é
  # Api::Internal::AiExecuteToolController ao receber uma chamada de "avancar_etapa".
  def current_step
    @current_step ||= state_manager.current_step(@department)
  end
end
