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
  # Tem que ser MAIOR que o TURN_BUDGET_SECONDS do orquestrador (default 90s lá), senão o Rails
  # desiste do POST enquanto o Python ainda está trabalhando: o turno segue rodando do outro lado —
  # salvando dado, avançando etapa, até transferindo sozinho — num turno que, para o cliente, nunca
  # existiu, e o conversation_id daquele atendimento se perde junto (o próximo turno começa uma
  # conversation nova). Configurável para quem ajustar o orçamento do lado Python.
  TIMEOUT = ENV.fetch('AI_ORCHESTRATOR_TIMEOUT', 120).to_i

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
    # Marca de início/fim com ticket_id=<conversation.id> — mesma chave que o Python usa em TODA linha
    # (ver orchestrator.py) — pra dar pra grepar "ticket_id=578" nos 3 serviços (Rails web, Sidekiq,
    # Python) e ver a história inteira de um atendimento junto, mesmo no caminho feliz (antes só os
    # logs de ERRO deste arquivo tinham alguma tag; sucesso não deixava rastro nenhum aqui).
    Rails.logger.info "[Ai::PythonOrchestratorClient] ticket_id=#{@conversation.id} POST #{ORCHESTRATOR_URL}"
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
      Rails.logger.error "[Ai::PythonOrchestratorClient] ticket_id=#{@conversation&.id} HTTP #{response.code}: #{response.body}"
      # conversation_id vem no corpo do erro quando a conversation da OpenAI já existia (ver
      # orchestrator.TurnFailed): repassado para o Ai::Gateway persistir mesmo assim, senão uma única
      # chamada com falha fazia o turno seguinte abrir uma conversation nova e perder o histórico.
      return { reply: nil, conversation_id: failed_conversation_id(response), byok_fallback: false,
               confidence: nil, transferred: false }
    end

    parsed = response.parsed_response
    Rails.logger.info "[Ai::PythonOrchestratorClient] ticket_id=#{@conversation.id} reply_present=#{parsed['reply'].present?} conversation_id=#{parsed['conversation_id'].inspect}"
    { reply: parsed['reply'], conversation_id: parsed['conversation_id'], byok_fallback: parsed['byok_fallback'] == true,
      # Auto-relato do modelo (0.0-1.0, orchestrator.CONFIANCA_KEY) — nil quando o Python não conseguiu
      # parsear o JSON do turno. Ai::Gateway usa isto pra decidir handoff por baixa confiança
      # (Ai::HandoffEvaluator); este client só repassa o que o Python mandou.
      confidence: parsed['confidence'], transferred: parsed['transferred'] == true }
  rescue StandardError => e
    Rails.logger.error "[Ai::PythonOrchestratorClient] ticket_id=#{@conversation&.id} #{e.class}: #{e.message}"
    { reply: nil, conversation_id: nil, byok_fallback: false, confidence: nil, transferred: false }
  end

  private

  # detail do HTTPException que o orquestrador levanta quando o turno falha DEPOIS de a conversation
  # existir. Corpo não-JSON (502 de proxy, timeout do gateway) simplesmente não tem id — devolve nil.
  def failed_conversation_id(response)
    parsed = response.parsed_response
    parsed.is_a?(Hash) ? parsed.dig('detail', 'conversation_id') : nil
  rescue StandardError
    nil
  end

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

    Ai::TemperatureMapper.resolve(operation_profile.supervisor_provider, operation_profile.temperature_position,
                                  model: operation_profile.supervisor_model)
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
    # Removido (17/08, decisão de produto): as guardrails fixas contra invenção/concorrentes/
    # transferência precoce/erro de ferramenta/perguntas em lote (identity_instruction,
    # market_average_guardrail, no_fabrication_instruction, transfer_discipline_instruction,
    # tool_error_instruction, gradual_conversation_instruction) saíram do código — apareciam por
    # inteiro no log de toda chamada (visibilidade operacional indesejada) e o pedido do produto é que
    # cada conta defina seu próprio comportamento via "Prompt base da empresa" em vez de um texto
    # universal fixo. Ai::PromptAssistant::Prompts::BASE_PROMPT_SYSTEM foi ajustado pra instruir o
    # assistente que ajuda a escrever o base_prompt a sempre embutir equivalentes adaptados ao
    # segmento do cliente — a proteção não depende mais só do admin lembrar sozinho. Texto original
    # arquivado fora do código (pedido do usuário) para eventual reversão.
    # identify_as_instruction NÃO foi removida — não é uma guardrail de bug, é o mecanismo que o
    # toggle "Como ele deve se identificar" (agent.identify_as) usa pra funcionar (inclusive o
    # contrato de formatação \n\n que Ai::ActionDispatcher#split_parts lê pra quebrar em várias
    # mensagens); por isso desceu pra perto do bloco de identidade/base_prompt, não ficou solta com
    # as guardrails removidas.
    # handoff_target_instruction removido (18/08, pedido do dono da conta — redução de prompt): não
    # estava marcado pra ficar. RISCO REAL, não cosmético — reverte exatamente o bug achado ao vivo em
    # 17/08 (ver histórico git): sem essa instrução, o modelo não tem como saber os nomes válidos de
    # time, "handoff_target" volta sempre vazio, e Ai::HandoffCoordinator#human_team_id cai sempre no
    # time DEFAULT (o primeiro da whitelist) — para contas com 2+ times marcados em "Transferir para
    # times (humanos)", a IA perde a capacidade de rotear por intenção; tudo vai pro mesmo time. Pra
    # contas com só 1 time marcado (caso desta conta hoje), o default já É esse time — sem efeito
    # prático até que um segundo time seja marcado. Decisão do dono da conta, ciente do risco.
    #
    # "Você é #{nome}." removido (18/08, pedido do dono da conta — redução de prompt): não estava
    # marcado pra ficar, e o nome do agente é texto livre digitado pelo admin — poderia expor qualquer
    # coisa verbatim no prompt (ex.: um nome tipo "agente de suporte da turma do fundão").
    # Pedido do dono da conta (19/08): identify_as_instruction ("Aja como um atendente humano da
    # equipe...") remanejada pra DEPOIS do prompt geral do agente (base_prompt) — antes vinha antes.
    lines << @agent.base_prompt if @agent.base_prompt.present?
    lines << identify_as_instruction
    lines << "Personalidade: #{@agent.assistant_personality}." if @agent.assistant_personality.present?
    # "Responda no idioma X" removido (18/08, pedido do dono da conta — redução de prompt).
    lines << "Regras de segurança (nunca viole): #{@agent.guardrails}." if @agent.guardrails.present?
    # Pedido do dono da conta (19/08): "Departamento: X. Objetivo: Y." virou "Agente de IA: X." —
    # department.objetivo NUNCA teve campo de edição na tela (só existia no payload/checklist, sempre
    # vazio pra todo mundo — "Objetivo: ." sem nada depois). Nome trocado de department.name pro nome
    # do AGENTE (o que o usuário realmente reconhece e configura).
    lines << "Agente de IA: #{@agent.assistant_name.presence || @agent.name}."
    lines << "Transfira para humano quando: #{transfer_when_text}." if transfer_when_text.present?
    lines << "Encerre quando: #{close_when_text}." if close_when_text.present?
    lines << "Mensagem de encerramento sugerida: #{close_message}." if close_message.present?

    # DINÂMICO — muda a cada turno (documento anexado neste turno, fatos acumulados, ai_step_index
    # avança). Fica no FINAL, contíguo, nunca antes do bloco estático acima.
    lines << document_extraction_instruction if image_urls.present?
    lines << collected_facts_block if collected_facts_block.present?
    lines << customer_memory_block if customer_memory_block.present?
    lines << "ETAPA ATUAL:\n#{current_step_instructions}" if current_step_instructions.present?
    lines << "PRÓXIMA ETAPA (só contexto — NÃO é a atual; NÃO pule pra ela, NÃO peça o dado dela, e " \
             "NÃO execute nenhuma ação ou ferramenta que ela descreva (ex.: transferir_humano, " \
             "encerrar_atendimento) antes da hora — só a etapa ATUAL manda no que fazer AGORA, mesmo " \
             "que você já tenha todos os dados que a próxima etapa pediria; mas se o cliente ADIANTAR " \
             "um DADO dela por conta própria, capture normalmente — ver REGRAS DE FOCO E VALIDAÇÃO DA " \
             "COLETA abaixo; use isso só pra conduzir a conversa com continuidade, sem soar como se não " \
             "soubesse o que vem a seguir):\n#{next_step_instructions}" \
      if next_step_instructions.present?
    # Pedido do dono da conta (19/08): structured_output_instruction (REGRAS: avancar_etapa/
    # transferir_humano/encerrar_atendimento) SAIU do bloco estático de identidade/guardrails e
    # desceu pra cá — junto do grupo de regras de comportamento por turno (REGRA DE EXTRAÇÃO/REGRAS DE
    # FOCO/DISCIPLINA DE FERRAMENTAS), não mais perto de "Transfira para humano quando"/departamento.
    # Conteúdo idêntico, só mudou de lugar.
    lines << structured_output_instruction
    lines << step_extraction_instruction if step_extraction_instruction.present?
    lines << data_validation_instruction if data_validation_instruction.present?
    lines << tool_discipline_instruction if tool_discipline_instruction.present?
    lines << force_handoff_instruction if @force_handoff_notice
    lines.join("\n")
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
  # Pedido do dono da conta (18/08, redução de prompt): tirado "Não diga que é uma inteligência
  # artificial" — o pedido foi cortar texto/regra em geral. Risco assumido: sem essa frase explícita,
  # "Aja como um atendente humano" sozinho pode não bastar se o cliente perguntar direto "você é um
  # robô?" — a IA pode acabar admitindo. Reversível revertendo este commit.
  def identify_as_instruction
    if @agent.identify_as == 'ai'
      'Você é um assistente virtual (IA) e pode assumir isso se perguntarem.'
    else
      'Aja como um atendente humano da equipe. Quando a resposta tiver mais de uma ideia ou ficar ' \
        'longa, escreva como uma pessoa real digitando: separe em mensagens curtas com uma LINHA EM ' \
        'BRANCO entre elas (dois \n) no campo "mensagem_para_cliente". Se for algo curto, responda em ' \
        'uma mensagem só, sem quebrar à força.'
    end
  end

  # handoff_target_instruction removido (18/08) — ver comentário em #system_prompt (risco assumido).
  # Existiu pra consertar o achado ao vivo de 17/08: sem ela, "transferir_humano" volta a ser um
  # boolean cego e toda transferência cai no time default (git history tem o texto original).

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

  # Achado ao vivo (17/08): Ai::StateManager#mirror_contact_facts já grava em Ai::CustomerMemory (dados
  # do CONTATO, cross-conversa/cross-agente) a cada turno — mas até aqui nada no caminho Python lia essa
  # memória de volta. O motor Ruby legado tinha isso (Ai::PromptCompiler#customer_memory_lines +
  # #memory_prefill_line — "DADO LEMBRADO DE ATENDIMENTO ANTERIOR, proponha e peça confirmação"); a
  # migração deixou a ESCRITA viva mas a LEITURA nunca acompanhou — um cliente que já deu CPF/cidade
  # numa conversa ANTERIOR era perguntado do zero de novo, com o dado dormindo no banco sem uso. Só
  # APRESENTA (dynamic — muda por contato, não por turno): o QUE FAZER com o dado (usar direto vs propor
  # e confirmar) fica pra instrução da etapa, igual o motor legado já decidia. nil sem contato ou sem
  # memória registrada ainda.
  def customer_memory_block
    return nil if @conversation.contact_id.blank?

    memory = Ai::CustomerMemory.find_by(contact_id: @conversation.contact_id, account_id: @department.account_id)
    return nil if memory.nil?

    facts = memory.key_facts.to_h.reject { |_k, v| v.to_s.strip.blank? }
    return nil if memory.summary.blank? && facts.blank?

    lines = ['MEMÓRIA DESTE CLIENTE (de atendimentos ANTERIORES, não desta conversa — pode citar; ' \
             'proponha e peça confirmação antes de tratar como definitivo, não afirme como certeza absoluta):']
    lines << "Resumo: #{memory.summary}" if memory.summary.present?
    if facts.present?
      lines << 'Dados lembrados:'
      facts.each { |key, value| lines << "- #{key}: #{value}" }
    end
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
  #
  # Achado ao vivo 2 (17/08, ticket 599 período de instalação): a regex só cobria o verbo "chame" —
  # texto salvo como "...usando a ferramenta registrar_periodo_reservado..." (verbo "usando", não
  # "chame") passava direto sem sanitizar. A IA leu, não achou a tool (não é mais oferecida), e
  # simplesmente NUNCA escreveu o dado em "dados_coletados" — sem erro visível, a mensagem pro cliente
  # ("vou reservar para X") saiu normal, só o dado morreu no meio do caminho (mesma classe do bug de
  # "dizer que salvou sem preencher dados_coletados" que #structured_output_instruction proíbe, mas a
  # regra geral não tem chance de agir se a instrução ESPECÍFICA da etapa manda usar uma tool que não
  # existe). Ampliado pra cobrir os verbos comuns encontrados em texto de etapa pré-migração.
  def sanitize_stale_tool_calls(text)
    return text if text.blank?

    verbos = 'chame|chamar|use|usando|utilize|utilizando'
    sanitized = text.dup
    sanitized.gsub!(/(?:#{verbos})\s+(?:imediatamente\s+)?a\s+(?:ferramenta|tool)\s+['"]?registrar_\w+['"]?\s*(?:correspondente)?/i,
                     'inclua esse dado em "dados_coletados" no seu JSON de resposta')
    sanitized.gsub!(/(?:#{verbos})\s+(?:imediatamente\s+)?a\s+(?:ferramenta|tool)\s+['"]?avancar_etapa['"]?/i,
                     'defina "avancar_etapa": true no seu JSON de resposta')
    sanitized.gsub!(/(?:#{verbos})\s+(?:imediatamente\s+)?a\s+(?:ferramenta|tool)\s+['"]?salvar_memoria_ia['"]?/i,
                     'inclua esse dado em "dados_coletados" no seu JSON de resposta')
    sanitized.gsub!(/(?:#{verbos})\s+(?:imediatamente\s+)?a\s+(?:ferramenta|tool)\s+['"]?conversation[._]transfer['"]?/i,
                     'defina "transferir_humano": true no seu JSON de resposta')
    sanitized.gsub!(/(?:#{verbos})\s+(?:imediatamente\s+)?a\s+(?:ferramenta|tool)\s+['"]?conversation[._]resolve['"]?/i,
                     'defina "encerrar_atendimento": true no seu JSON de resposta')
    sanitized
  end

  # Achado pelo usuário: o admin escreve SÓ "Objetivo"/"Regras" em linguagem natural na tela da etapa
  # (AiStepForm.vue) — "JSON"/"dados_coletados" nunca deveriam aparecer ali. Esta regra é montada AQUI
  # pelo Rails, nunca digitada pelo admin, a partir do "Dado que esta etapa coleta" (o Select que grava
  # collect.attribute — MESMA fonte, Ai::StepSlot.declared_attributes, que o design antigo de
  # function-calling usava pra nomear a tool "registrar_<attribute>", Ai::StepCaptureTool). Complementa
  # (não substitui) #structured_output_instruction: aquela é a regra GERAL do contrato JSON; esta nomeia
  # a(s) chave(s) exata(s) que importa(m) NESTA etapa, pra IA não "escolher" um nome de chave por conta
  # própria. nil numa etapa informativa (sem collect) — não força a IA a inventar uma chave que não existe.
  #
  # Etapa com MAIS de um atributo declarado (achado ao vivo 16/08, ticket 586): collect.attribute aceita
  # string OU array desde sempre (Api::Internal::AiExecuteToolController#collect_attributes já usava
  # Array() puro pra validar avanço), mas ESTE método fazia `Ai::StepSlot.attribute` (só o 1º/único) e
  # colava um array de 2 atributos numa ÚNICA chave colada (ex.: '["cidade", "viabilidade"]') — a IA só
  # tinha instrução/ferramenta pra escrever essa chave colada, nunca as duas chaves reais que a validação
  # de avanço exigia separadas. A etapa nunca completava: o cliente respondia certo, avancar_etapa vinha
  # true, mas o teto de "travado" (stuck_handoff_turns) ia subindo turno a turno até estourar e transferir
  # pra humano — sem NADA de errado visível na conversa. Agora gera um item de "dados_coletados" por
  # atributo declarado, sempre.
  def step_extraction_instruction
    attributes = Ai::StepSlot.declared_attributes(current_step)
    return nil if attributes.empty?

    if attributes.one?
      attribute = attributes.first
      "REGRA DE EXTRAÇÃO JSON: Nesta etapa, você deve extrair o dado referente a '#{attribute}' " \
        "(#{step_slot_metadata_text}). Assim que o cliente informar isso, você DEVE adicionar um item na " \
        "lista \"dados_coletados\" no seu JSON de resposta com \"chave\": \"#{attribute}\" e o valor " \
        'extraído.'
    else
      lista = attributes.map { |a| "'#{a}'" }.join(', ')
      "REGRA DE EXTRAÇÃO JSON: Nesta etapa, você deve extrair os dados referentes a #{lista} " \
        "(#{step_slot_metadata_text}) — CADA um vira um item PRÓPRIO em \"dados_coletados\", nunca uma " \
        'única chave combinando os dois. Assim que o cliente informar cada um, adicione o item ' \
        'correspondente com "chave" igual ao nome exato do atributo e o valor extraído.'
    end
  end

  # Tipo/opções/obrigatoriedade do slot da etapa ATUAL, pro contexto de #data_validation_instruction
  # ter algo real pra validar contra — sem isso a IA só teria o NOME do atributo, sem saber se é CPF,
  # telefone, uma lista fechada de opções, etc. tools_schema TINHA essa info (o input_schema de
  # "registrar_<attribute>"), mas essa tool é filtrada antes de chegar à OpenAI (orchestrator.py) — só
  # sobrava o nome da chave. Ai::StepSlot é a MESMA fonte que gerava aquele input_schema.
  #
  # type/options (collect['type']/collect['options']) existem UMA vez por ETAPA, não por atributo — numa
  # etapa de vários atributos aplicar o mesmo tipo/enum a todos seria errado (ex.: enum de cidades
  # vazando pro atributo "viabilidade" da mesma etapa), então esse caso cai pro genérico
  # obrigatório/opcional, sem tipo/opções (mesmo critério de Ai::StepCaptureTool#property_schema).
  def step_slot_metadata_text
    required = !Ai::StepSlot.optional?(current_step)
    return required ? 'OBRIGATÓRIO' : 'opcional' if Ai::StepSlot.multi_attribute?(current_step)

    type = Ai::StepSlot.type(current_step)
    options = Ai::StepSlot.options(current_step)

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
    attributes = Ai::StepSlot.declared_attributes(current_step)
    return nil if attributes.empty?

    foco = attributes.one? ? "\"#{attributes.first}\"" : attributes.map { |a| "\"#{a}\"" }.join(' e ')
    dado = attributes.one? ? 'o dado' : 'os dados'

    "REGRAS DE FOCO E VALIDAÇÃO DA COLETA (além da regra geral de \"dados_coletados\" acima):\n" \
      "- Extraia para \"dados_coletados\" APENAS #{dado} que a etapa atual está pedindo " \
      "explicitamente (#{foco}, ver REGRA DE EXTRAÇÃO JSON). Se o cliente disser algo avulso, fora do foco " \
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
      "- Se o valor NÃO bater com o tipo: explique o problema de forma isolada e direta — não repita " \
      "a etapa inteira, só aponte o que falta corrigir — e peça de novo. Campo opcional: se o cliente " \
      "não corrigir, não grave nada nessa chave e siga em frente. Campo OBRIGATÓRIO: continue pedindo " \
      "com paciência — NÃO marque \"transferir_humano\" só pela quantidade de tentativas (o sistema " \
      "tem seu próprio limite de segurança pra isso, configurado à parte).\n" \
      "- Se o cliente simplesmente NÃO fornecer o dado pedido: peça de novo, com paciência. Campo " \
      "opcional: se ele não responder, mande \"dados_coletados\" vazio ([]) e defina " \
      '"avancar_etapa": true. Campo OBRIGATÓRIO: continue pedindo — mesma regra acima, não transfira ' \
      'só pela contagem de tentativas.'
  end

  # Achado ao vivo (17/08, ticket 595): a IA perguntou "qual cidade..." (assunto de uma etapa
  # SEGUINTE) logo na etapa 1, quando nem ETAPA ATUAL nem PRÓXIMA ETAPA mencionavam cidade em lugar
  # nenhum — a instrução de "PRÓXIMA ETAPA... NÃO execute ação/ferramenta antes da hora" (acima) só
  # cobre a ÚNICA etapa de preview, não as tools REAIS do department (Ai::Tool, #real_tools), que
  # ficam SEMPRE disponíveis pra qualquer etapa (agentic, sem gate por índice — ver comentário no topo
  # do arquivo) e continuam listadas em tools_schema o turno inteiro, seja qual for a etapa atual.
  # Hipótese confirmada por log real: 2 das tools reais deste department pedem "cidade" como parâmetro
  # (Consultar_Viabilidade/consultar_periodos) — a IA provavelmente "puxou" o assunto delas por conta
  # própria, sem nenhuma etapa ainda pedir isso. Esta regra fecha essa lacuna: mesmo com a tool sempre
  # visível, só pode ser chamada (ou o dado que ela pede, só perguntado) quando ETAPA ATUAL realmente
  # tratar desse assunto. nil quando o department não tem nenhuma tool real configurada — nada a
  # disciplinar.
  def tool_discipline_instruction
    return nil if real_tools.empty?

    'DISCIPLINA DE FERRAMENTAS: as ferramentas reais listadas acima ficam SEMPRE disponíveis durante ' \
      'toda a conversa, independente da etapa atual — isso NÃO significa que você deve usá-las (ou ' \
      'pedir o dado que elas pedem, tipo cidade/CPF/endereço) fora de hora. Só chame uma ferramenta, ' \
      'ou peça o dado que ela precisa, quando ETAPA ATUAL pedir esse assunto explicitamente. Se o ' \
      'cliente adiantar esse dado por conta própria, tudo bem capturar/usar a ferramenta; mas NUNCA ' \
      'puxe o assunto de uma ferramenta por iniciativa própria só porque ela está disponível.'
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

  # Achado ao vivo (17/08): a regra antiga ("encerrar_atendimento: true SOMENTE quando as condições de
  # encerramento configuradas ABAIXO forem atendidas") referencia uma lista que só existe no prompt
  # quando #close_when_text está presente (linha "Encerre quando: ..." logo acima, ver #system_prompt).
  # Pra department SEM close_when configurado (comum — o desfecho normal vem do on_complete de uma
  # etapa, não de uma condição solta), a IA ficava com "as condições configuradas abaixo" apontando pra
  # NADA — e mesmo assim, um cliente respondendo algo tão simples quanto "ta bem obrigada" foi
  # suficiente pra ela marcar encerrar_atendimento:true, pulando etapas restantes inteiras (incluindo a
  # etapa de Finalização, cujo desfecho configurado era TRANSFERIR pra um time humano, não resolver).
  # Provavelmente puxada pela "Mensagem de encerramento sugerida" (#close_message) sempre presente no
  # prompt mesmo sem gatilho — ter uma despedida pronta parece ter bastado. Fecha a ambiguidade: sem
  # close_when, a regra vira uma proibição explícita, sem "abaixo" nenhum pra apontar pro vazio.
  # Pedido do dono da conta (18/08, redução de prompt): cortado o meio ("não existe nenhuma condição...
  # NUNCA marque true por conta própria") e o final ("isso é automático... você não precisa fazer nada a
  # mais") do ramo sem close_when — mantido só o essencial marcado por ele. Risco assumido: é justamente
  # esse texto cortado que travou o bug original (17/08) de a IA encerrar um atendimento sozinha ao ouvir
  # "ta bem obrigada" — com a regra mais curta, a chance de reincidência é maior.
  def encerrar_atendimento_rule
    return '- "encerrar_atendimento": true SOMENTE quando as condições de encerramento configuradas ' \
           'abaixo forem atendidas.' if close_when_text.present?

    '- "encerrar_atendimento": mantenha SEMPRE false — mesmo que o cliente agradeça, se despeça ou ' \
      'pareça satisfeito — isso NÃO é sinal de que o atendimento deve terminar. A única forma correta ' \
      'de concluir é a etapa atual alcançar o desfecho configurado dela.'
  end

  # Substitui a antiga instrução de function-calling (tool_usage_instruction/
  # must_call_capture_tools_instruction/no_confirmation_loop_instruction — removidas): orchestrator.py
  # não oferece mais "registrar_*"/"avancar_etapa"/"salvar_memoria_ia"/"continuar_conversa"/
  # conversation.resolve/conversation.transfer como tools à OpenAI (Ai::PythonOrchestratorClient nem
  # mais calcula essas tools em #tools_schema — removido por serem puro overhead, nunca usadas).
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
  # Pedido do dono da conta (18/08, redução de prompt): ele viu o texto completo indo pra OpenAI (log)
  # e pediu corte agressivo, marcando à mão só o que devia sobreviver. Cortado:
  #  - todo o bloco "FORMATO DE RESPOSTA OBRIGATÓRIO" com o JSON por extenso — é REDUNDANTE (o mesmo
  #    formato já vai separado em response.text.format=json_schema, orchestrator.py, e a OpenAI valida a
  #    resposta contra ele antes de devolver); cortar isso é seguro, não muda comportamento.
  #  - a regra de "confiança" (o campo "confianca" continua OBRIGATÓRIO pelo json_schema — só perdeu a
  #    explicação de como calcular; risco: a pontuação pode ficar menos criteriosa, o campo não some).
  #  - a regra de "adicione UM ITEM em dados_coletados por dado" (idem — "dados_coletados" continua no
  #    schema; só perdeu a explicação de chave/valor/atualiza-não-duplica; risco: extração mais solta).
  #  - as 2 regras "É ESTRITAMENTE PROIBIDO" de fake-transfer/fake-close E a de "fake-save" de dado —
  #    RISCO REAL: são as 3 regras que corrigiram bugs ao vivo documentados (dado perdido silenciosamente,
  #    IA dizendo "vou transferir" sem transferir, IA encerrando sem marcar o campo). Sem elas, esses 3
  #    bugs podem voltar. Decisão do dono da conta, ciente do risco (revertível: branch isolada).
  def structured_output_instruction
    "REGRAS:\n" \
      "- Assim que o cliente responder o que a etapa atual pede, NÃO peça confirmação ('é isso mesmo?', " \
      "'posso confirmar?') — registre o dado em \"dados_coletados\" E marque \"avancar_etapa\": true na " \
      "MESMA resposta, sem inserir um turno extra de confirmação.\n" \
      "- \"avancar_etapa\": true quando a etapa atual estiver concluída, ou quando o cliente recusar um " \
      "dado opcional (avance com empatia, sem forçar); caso contrário, false.\n" \
      "- \"transferir_humano\": true SOMENTE quando precisar transferir para um atendente humano; nesse " \
      "caso preencha \"handoff_summary\" com o que já foi conseguido (ex: \"Cliente já forneceu nome e " \
      "cidade, falta CPF\") e o motivo da transferência.\n" \
      "#{encerrar_atendimento_rule}"
  end

  def force_handoff_instruction
    'LIMITE DE TENTATIVAS ATINGIDO NESTA ETAPA. Responda AGORA com "transferir_humano": true e ' \
      '"handoff_summary" preenchido, mesmo que a etapa não tenha concluído.'
  end

  # Só as tools que REALMENTE chegam à OpenAI: tools reais do department (webhooks/capabilities/
  # integrations) + a busca de conhecimento (quando há base cadastrada). Nomes SANITIZADOS
  # (Ai::ToolNameSanitizer) — a OpenAI rejeita qualquer coisa fora de [a-zA-Z0-9_-] (400 "does not
  # match pattern"), e as chaves do Ai::CapabilityRegistry são pontuadas (conversation.resolve,
  # conversation.add_label, contact.update_attributes...) por convenção. Api::Internal::
  # AiExecuteToolController reverte isso batendo o nome recebido contra o catálogo real do department,
  # não adivinhando "_" == ".".
  #
  # ANTES este método também gerava "registrar_*" (uma por atributo conhecido do playbook/conta —
  # Ai::StepCaptureTool) e as 5 tools de controle (continuar/memória genérica/avançar/encerrar/
  # transferir): puro desperdício com o Structured Outputs (orchestrator.py) — o Python já FILTRAVA
  # tudo isso antes de montar a lista pra OpenAI (nunca chegava lá), e o tipo/opções que só existia no
  # input_schema dessas tools sintéticas já foi migrado pra #step_slot_metadata_text (lido direto de
  # Ai::StepSlot). Removido (17/08): Rails parou de calcular e mandar esse catálogo morto a cada turno
  # — menos CPU aqui, payload HTTP menor Rails->Python, menos filtro do lado Python. Confirmado seguro:
  # Api::Internal::AiExecuteToolController#create resolve TODOS os nomes recebidos (inclusive os de
  # controle) por constante fixa/DB, nunca reconsultando este catálogo enviado antes.
  def tools_schema
    real_tools + knowledge_tools
  end

  def real_tools
    @real_tools ||= @department.tools.active.map do |tool|
      { name: Ai::ToolNameSanitizer.sanitize(tool.name), description: tool.description, input_schema: tool.input_schema }
    end
  end

  def state_manager
    @state_manager ||= Ai::StateManager.new(conversation: @conversation, agent: @agent)
  end

  # "consultar_conhecimento" tem que ser uma function tool DE VERDADE, oferecida à OpenAI e chamada NO
  # MEIO do turno (mesmo loop de tool-call que já atende tools reais tipo consultar_periodos) — o
  # resultado da busca precisa voltar pra IA ANTES dela montar a resposta final, não depois. Sem query
  # pré-configurada nem filtro de tipo — a IA formula a pergunta e decide quando chamar, a partir do
  # objetivo da etapa + o que o cliente perguntou.
  #
  # Condicional a #has_knowledge?: oferecer a ferramenta sem NENHUM conhecimento cadastrado só ensina a
  # IA a chamar algo que sempre volta vazio — gasta uma rodada de tool-call à toa e engorda
  # tools_schema à toa.
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
