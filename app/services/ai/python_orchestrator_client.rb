# Bridges Ai::Gateway to the Python AI orchestrator microservice, which owns the OpenAI Responses
# API reasoning/tool-call loop for a turn (native OpenAI tools like file_search resolved entirely
# in Python; Rails-side tools proxied back via Api::Internal::AiExecuteToolController). Replaces
# Ai::ContextBuilder + Ai::ModelRouter for departments opted into this path — Gateway keeps billing,
# department resolution and final delivery (Ai::ActionDispatcher) exactly as before.
#
# History: no flattened message blob is sent. previous_response_id (reused from the SAME
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
# tool_choice="required" (orchestrator.py, live bug: the AI replied with text-only confirmation loops
# and never called any tool, so ai_step_index never advanced): the Responses API now FORCES a tool
# call every turn. CONTINUE_TOOL ("continuar_conversa") exists so that constraint is never a trap — a
# genuine no-op the model can call when it only wants to talk (greet, ask, answer a question) without
# registering data or advancing the step. Without it, tool_choice="required" would force the AI to
# misuse a real tool (advance early, save garbage) on every turn that has nothing to actually save.
#
# Round 2 of that same bug (live, worse): the AI found the OPPOSITE abuse of CONTINUE_TOOL — calling
# it to satisfy tool_choice="required" cheaply while claiming in text ("Recebi seu CPF!") that it saved
# a REAL customer-provided datum, without ever calling registrar_*/salvar_memoria_ia. Nothing
# persisted, so the next step re-asked for the same data (loop). #must_call_capture_tools_instruction
# and CONTINUE_TOOL's own description were both sharpened to name this exact failure mode.
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
  # No-op de propósito: existe SÓ pra dar à IA uma opção válida quando orchestrator.py manda
  # tool_choice="required" (loop de confirmação — a IA respondia só com texto e nunca chamava
  # nenhuma tool, então o Rails nunca avançava o índice). Sem esta tool, tool_choice="required" forçaria
  # a IA a chamar registrar_*/avancar_etapa mesmo quando só quer falar (cumprimentar, tirar dúvida,
  # fazer a PRIMEIRA pergunta de uma etapa nova) — risco pior que o bug original (avanço/registro
  # prematuro). O controller NUNCA toca o banco por causa dela (ver #continue_conversation).
  CONTINUE_TOOL = 'continuar_conversa'
  # Catch-all de memória (híbrida, deliberado — ver #memory_tool): complementa "registrar_*", não
  # substitui. Pra atributo JÁ conhecido (collect ou CustomAttributeDefinition), "registrar_*" é
  # SEMPRE a via certa — o nome da tool garante a chave exata, sem risco de a IA inventar uma chave
  # livre que não bate com o CustomAttributeDefinition e o espelhamento pra custom_attributes falhar
  # em silêncio (já aconteceu neste projeto uma vez, com o modelo escrevendo "cidade_usuario" em vez
  # de "cidade"). Esta tool é só pro que SOBRA: contexto que o cliente deu e não tem "botão" nenhum.
  MEMORY_TOOL = 'salvar_memoria_ia'

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
      return { reply: nil, response_id: nil }
    end

    parsed = response.parsed_response
    { reply: parsed['reply'], response_id: parsed['response_id'] }
  rescue StandardError => e
    Rails.logger.error "[Ai::PythonOrchestratorClient] #{e.class}: #{e.message}"
    { reply: nil, response_id: nil }
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
      # sincronização existir; até lá, a base de conhecimento chega pelo #knowledge_block abaixo
      # (Ai::KnowledgeRetriever — pgvector, já populado, mesmo mecanismo do caminho legado).
      vector_store_id: @department.behavior.to_h['vector_store_id'],
      user_input: @content.to_s,
      # WhatsApp image: the RAW url (not the MediaProcessor text caption already folded into
      # @content upstream in Ai::Gateway) — lets the model's own vision read the image directly
      # instead of relying only on the auxiliary caption worker.
      image_url: image_url,
      previous_response_id: @conversation.additional_attributes&.dig('openai_conversation_id'),
      # Multi-tenant: cada Account escolhe seu próprio modelo/temperatura via Ai::OperationProfile
      # (tela de admin). nil quando o agente não tem perfil — o orquestrador cai no OPENAI_MODEL do
      # seu próprio .env e deixa a OpenAI usar o default de temperatura, não hardcodeia nada aqui.
      model: operation_profile&.supervisor_model,
      temperature: temperature
    }
  end

  def image_url
    @message&.attachments&.to_a&.find { |a| a.file_type == 'image' }&.download_url.presence
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
    # Fixas e inegociáveis, ANTES de qualquer outra coisa: fecham lacunas achadas em teste ao vivo —
    # sugerir concorrentes, alucinar "médias de mercado" em vez do conhecimento real, "fingir" que
    # chamou registrar_* sem chamar de verdade, inventar situações que não existem, e transferir sem
    # motivo pulando o fluxo de etapas. (Múltiplas mensagens por turno NÃO entra aqui — é o
    # comportamento esperado do modo identify_as="human", intencional.)
    lines << identity_instruction
    lines << market_average_guardrail
    lines << must_call_capture_tools_instruction
    lines << no_confirmation_loop_instruction
    lines << no_fabrication_instruction
    lines << transfer_discipline_instruction
    lines << gradual_conversation_instruction
    lines << "Você é #{@agent.assistant_name.presence || @agent.name}."
    lines << @agent.base_prompt if @agent.base_prompt.present?
    lines << "Personalidade: #{@agent.assistant_personality}." if @agent.assistant_personality.present?
    lines << "Responda no idioma #{@agent.assistant_language}." if @agent.assistant_language.present?
    lines << "Regras de segurança (nunca viole): #{@agent.guardrails}." if @agent.guardrails.present?
    lines << "Departamento: #{@department.name}. Objetivo: #{@department.objetivo}."
    kb = knowledge_block
    lines << kb if kb.present?
    lines << collected_facts_block if collected_facts_block.present?
    lines << "ETAPA ATUAL:\n#{current_step_instructions}" if current_step_instructions.present?
    lines << "Transfira para humano quando: #{transfer_when_text}." if transfer_when_text.present?
    lines << "Encerre quando: #{close_when_text}." if close_when_text.present?
    lines << "Mensagem de encerramento sugerida: #{close_message}." if close_message.present?
    lines << tool_usage_instruction
    lines << force_handoff_instruction if @force_handoff_notice
    lines.join("\n")
  end

  # Texto do pedido, com UM ajuste: a frase original citava "a ferramenta de busca (file_search)" —
  # mas não existe vector store nenhum aqui (ver comentário em #payload), então instruir a IA a chamar
  # uma tool que não existe seria pior que o problema original. Aponta pro bloco de conhecimento que
  # o Rails já injeta abaixo (#knowledge_block) em vez disso — mesma intenção, mecanismo real.
  def identity_instruction
    'IDENTIDADE: Você é um atendente de IA DA PRÓPRIA EMPRESA. A empresa para quem você trabalha É a ' \
      'provedora do serviço. É ESTRITAMENTE PROIBIDO sugerir que o cliente procure outras empresas, ' \
      'operadoras ou provedores. Se o cliente quiser preços, planos ou dúvidas, consulte o bloco ' \
      '"CONHECIMENTO OFICIAL DA EMPRESA" abaixo antes de responder — nunca invente o que não estiver lá.'
  end

  # Reforço explícito contra "médias de mercado": IA alucinava preço/regra plausível-mas-inventado
  # em vez de usar o conhecimento real, e só se corrigia quando o cliente reclamava — reforça a
  # mesma proibição de #identity_instruction com outra frase, mirando especificamente esse padrão.
  def market_average_guardrail
    'Você é um atendente DA EMPRESA. Nunca cite concorrentes, médias de mercado ou valores que não ' \
      'estejam no bloco de conhecimento abaixo.'
  end

  # Achado em teste ao vivo (2 rodadas): (1) a IA "fingia" ter anotado um dado (reply_text tipo "Anotei
  # seu nome!") sem de fato chamar registrar_*, então nada era persistido. (2) DEPOIS que
  # tool_choice="required" (ver #no_confirmation_loop_instruction) passou a forçar alguma tool a cada
  # turno, a IA achou um jeito NOVO de continuar fingindo: chamava "continuar_conversa" (o no-op —
  # existe pra quando ela só quer FALAR, não pra escapar de salvar) e dizia em texto "Recebi seu CPF!"
  # sem NUNCA chamar registrar_*/salvar_memoria_ia — satisfaz a exigência da API sem salvar nada, o
  # cliente repete o dado na etapa seguinte (loop). Por isso a regra abaixo é redundante de propósito
  # com o resto do prompt: cita os dois nomes de tool de salvamento E nomeia "continuar_conversa"
  # explicitamente como NÃO valendo pra esse caso.
  def must_call_capture_tools_instruction
    'REGRA DE SALVAMENTO INEGOCIÁVEL: É ESTRITAMENTE PROIBIDO dizer "Recebi seu dado", "Anotado" ou ' \
      'qualquer variação sem ANTES chamar a tool "salvar_memoria_ia" ou a tool "registrar_*" ' \
      'correspondente. Chamar "continuar_conversa" NÃO CONTA como salvar — essa tool é só pra quando ' \
      'você não tem NENHUM dado novo pra registrar. Se o cliente forneceu um dado (nome, endereço, ' \
      'CPF, telefone, email, etc.) e você respondeu sem ter chamado a tool de salvamento, o dado será ' \
      'PERDIDO. Se você disser que anotou, você DEVE ter chamado a tool antes — nunca depois, nunca no ' \
      'próximo turno.'
  end

  # Achado em teste ao vivo (WhatsApp real): cliente disse "vendas", a IA respondeu "Perfeito, você
  # quer falar com o setor de vendas! Só pra confirmar, é vendas mesmo?" e ficou nesse loop — nunca
  # chamava registrar_*/avancar_etapa, só reconfirmava o mesmo dado. Instrução separada e agressiva de
  # #must_call_capture_tools_instruction porque o problema aqui não é deixar de chamar a tool (a IA às
  # vezes ATÉ chama), é INSERIR um turno de confirmação extra ANTES de chamar — o cliente já respondeu
  # e a IA pergunta de novo em vez de agir. Reforçada (2 rodadas ao vivo: o primeiro texto não bastou)
  # com passos numerados + o exemplo concreto "vendas" — o mesmo caso real que travou no WhatsApp.
  def no_confirmation_loop_instruction
    "REGRA DE AÇÃO IMEDIATA (OBRIGATÓRIO):\n" \
      "Assim que o cliente fornecer a informação solicitada pela etapa atual, você DEVE:\n" \
      "1. Chamar a tool 'registrar_*' correspondente para salvar o dado IMEDIATAMENTE.\n" \
      "2. Chamar a tool 'avancar_etapa' para avançar o fluxo.\n" \
      "É ESTRITAMENTE PROIBIDO pedir confirmação ('é isso mesmo?', 'posso confirmar?') para dados " \
      "que o cliente já falou claramente. Aja com decisão. Se o cliente falou 'vendas', salve " \
      "'vendas' e avance. Não responda apenas com texto, USE AS TOOLS."
  end

  # Achado em teste ao vivo: a IA inventava situações plausíveis mas inexistentes ("instabilidade no
  # sistema", "link seguro", "formulário externo") pra preencher lacunas em vez de admitir que não sabe.
  def no_fabrication_instruction
    'É PROIBIDO inventar situações, recursos ou funcionalidades que não existem (ex: "instabilidade no ' \
      'sistema", "link seguro", "formulário externo"). Se algo não estiver disponível, diga simplesmente ' \
      'que vai encaminhar para um especialista.'
  end

  # Achado em teste ao vivo: a IA transferia pra humano "achando" que devia, pulando o fluxo de etapas
  # inteiro — o "5 mensagens" aqui é um limite NARRATIVO fixo pedido pelo usuário, independente do teto
  # REAL enforçado no backend (Ai::Gateway#step_turns_exceeded?, transfer_rules['stuck_handoff_turns'],
  # default 10 — ver force_handoff_instruction). Os dois números podem divergir; documentado, não
  # unificado — o pedido foi por um texto fixo, não calculado a partir da config real.
  def transfer_discipline_instruction
    'SÓ transfira para humano se: o cliente pedir explicitamente, demonstrar frustração clara, ou se ' \
      'você já tentou cumprir a etapa atual por 5 mensagens sem sucesso. NUNCA transfira só porque ' \
      '"achou" que deve. Siga o fluxo de etapas até o final.'
  end

  # Achado em teste ao vivo (esclarecido pelo usuário: NÃO é sobre várias mensagens por turno — isso é
  # o modo identify_as="human" funcionando como esperado): a IA perguntava várias etapas de uma vez
  # (nome + endereço + CPF + telefone na mesma mensagem) em vez de conduzir uma pergunta por vez, mesmo
  # com TODAS as tools "registrar_*" disponíveis simultaneamente (fluxo agentic, sem gate por etapa).
  def gradual_conversation_instruction
    'Peça os dados da etapa atual UM DE CADA VEZ, de forma natural e conversacional — mesmo que várias ' \
      'ferramentas "registrar_*" estejam disponíveis ao mesmo tempo, não liste várias perguntas na mesma ' \
      'mensagem. Espere a resposta do cliente antes de pedir o próximo dado.'
  end

  # Ai::KnowledgeRetriever: pgvector, o MESMO mecanismo (e a MESMA base já populada) que o caminho
  # legado usa hoje — não o file_search/vector_store nativo da OpenAI (inexistente neste projeto).
  # Query = mensagem atual do cliente; [] sem fonte cadastrada ou sem query, o bloco nem aparece.
  # Cabeçalho agressivo/inegociável de propósito (## + maiúsculas): a versão anterior, mais suave
  # ("use para responder... não invente"), não impediu a IA de alucinar "médias de mercado" — só
  # se corrigia quando o cliente reclamava.
  def knowledge_block
    chunks = Ai::KnowledgeRetriever.retrieve(query: @content.to_s, account_id: @department.account_id,
                                             department_id: @department.id)
    return nil if chunks.blank?

    '## CONHECIMENTO OFICIAL DA EMPRESA (Use APENAS este texto para responder sobre planos/preços/regras. ' \
      'É PROIBIDO usar conhecimento externo, médias de mercado ou suposições. Se não estiver aqui, diga ' \
      "que não sabe):\n#{chunks.map { |c| "- #{c}" }.join("\n")}"
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
  def current_step_instructions
    Ai::StepInstructionText.render(current_step)
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

  def tool_usage_instruction
    'Use as ferramentas "registrar_*" para gravar cada dado assim que o cliente informar (pode chamar ' \
      'mais de uma na mesma resposta se ele adiantar vários dados de uma vez; chamar de novo com um valor ' \
      'diferente ATUALIZA o dado, não duplica). Se o cliente informar algo relevante que NÃO tem uma ' \
      'ferramenta "registrar_*" específica, use "salvar_memoria_ia" com chave=nome do dado (ex: "nome", ' \
      '"cpf", "plano") e valor=o que o cliente disse — nunca deixe uma informação relevante se perder só ' \
      'porque não existe uma tool dedicada para ela. Use "avancar_etapa" (sem parâmetros) quando julgar a ' \
      'etapa atual concluída, ou se o cliente recusar dar um dado opcional — avance com empatia, sem ' \
      "forçar. Se precisar encerrar o atendimento, use a tool \"#{sanitized_resolve_tool}\". Se precisar " \
      "transferir para um humano, use a tool \"#{sanitized_transfer_tool}\". Quando for transferir para um " \
      'humano, você DEVE preencher o parâmetro "handoff_summary" com um resumo do que já foi conseguido ' \
      '(ex: "Cliente já forneceu nome e cidade, falta CPF") e o motivo da transferência. TODA resposta ' \
      'sua PRECISA vir acompanhada de UMA chamada de ferramenta — nunca responda só com texto, sem ' \
      "chamar nada. Se você só precisa FALAR com o cliente (fazer uma pergunta, cumprimentar, tirar uma " \
      "dúvida) sem registrar nenhum dado nem avançar a etapa, chame \"#{sanitized_continue_tool}\" (sem " \
      'parâmetros) — ela não faz nada no sistema, existe só para liberar sua resposta em texto.'
  end

  def force_handoff_instruction
    'LIMITE DE TENTATIVAS ATINGIDO NESTA ETAPA. Transfira para um humano AGORA usando a tool ' \
      "\"#{sanitized_transfer_tool}\", mesmo que a etapa não tenha concluído."
  end

  # Tools reais do department (webhooks/capabilities/integrations) + UMA "registrar_*" por atributo
  # declarado em QUALQUER etapa do playbook (Ai::StepCaptureTool, todas de uma vez — fluxo agentic,
  # sem gate por etapa ativa) + as tools de controle (continuar/memória genérica/avançar/encerrar/
  # transferir — CONTINUE_TOOL é o no-op que sustenta tool_choice="required" no orchestrator.py). Nomes SANITIZADOS
  # (Ai::ToolNameSanitizer) — a OpenAI rejeita qualquer coisa fora de [a-zA-Z0-9_-] (400 "does not
  # match pattern"), e as chaves do Ai::CapabilityRegistry são pontuadas (conversation.resolve,
  # conversation.add_label, contact.update_attributes...) por convenção. Api::Internal::
  # AiExecuteToolController reverte isso batendo o nome recebido contra este MESMO catálogo
  # (department.tools.active + as 2 constantes de controle), não adivinhando "_" == ".".
  def tools_schema
    real_names = real_tools.map { |t| t[:name] }
    synthesized = step_capture_tools + control_tools
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

  # Leitura PURA do índice server-tracked (Ai::StateManager#current_step) — não roda track_step, não
  # avança nada; só lê o mesmo ai_step_index que o caminho legado também lê. Quem avança é
  # Api::Internal::AiExecuteToolController ao receber uma chamada de "avancar_etapa".
  def current_step
    @current_step ||= state_manager.current_step(@department)
  end
end
