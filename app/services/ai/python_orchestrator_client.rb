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
    lines << "Você é #{@agent.assistant_name.presence || @agent.name}."
    lines << @agent.base_prompt if @agent.base_prompt.present?
    lines << "Personalidade: #{@agent.assistant_personality}." if @agent.assistant_personality.present?
    lines << "Responda no idioma #{@agent.assistant_language}." if @agent.assistant_language.present?
    lines << "Regras de segurança (nunca viole): #{@agent.guardrails}." if @agent.guardrails.present?
    lines << "Departamento: #{@department.name}. Objetivo: #{@department.objetivo}."
    lines << "Etapa atual: #{current_step_instructions}" if current_step_instructions.present?
    lines << "Transfira para humano quando: #{transfer_when_text}." if transfer_when_text.present?
    lines << "Encerre quando: #{close_when_text}." if close_when_text.present?
    lines << "Mensagem de encerramento sugerida: #{close_message}." if close_message.present?
    lines << tool_usage_instruction
    lines << force_handoff_instruction if @force_handoff_notice
    lines.join("\n")
  end

  def current_step_instructions
    return nil unless current_step.is_a?(Hash)

    (current_step['instructions'] || current_step[:instructions]).to_s.strip.presence
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
      'diferente ATUALIZA o dado, não duplica). Use "avancar_etapa" (sem parâmetros) quando julgar a etapa ' \
      'atual concluída, ou se o cliente recusar dar um dado opcional — avance com empatia, sem forçar. Se ' \
      "precisar encerrar o atendimento, use a tool \"#{RESOLVE_TOOL}\". Se precisar transferir para um " \
      "humano, use a tool \"#{TRANSFER_TOOL}\"."
  end

  def force_handoff_instruction
    'LIMITE DE TENTATIVAS ATINGIDO NESTA ETAPA. Transfira para um humano AGORA usando a tool ' \
      "\"#{TRANSFER_TOOL}\", mesmo que a etapa não tenha concluído."
  end

  # Tools reais do department (webhooks/capabilities/integrations, inalteradas) + UMA "registrar_*" por
  # atributo declarado em QUALQUER etapa do playbook (Ai::StepCaptureTool, todas de uma vez — fluxo
  # agentic, sem gate por etapa ativa) + as tools de controle (avançar/encerrar/transferir).
  def tools_schema
    real_names = real_tools.map { |t| t[:name] }
    synthesized = step_capture_tools + control_tools
    real_tools + synthesized.reject { |t| real_names.include?(t[:name]) }
  end

  def real_tools
    @real_tools ||= @department.tools.active.map do |tool|
      { name: tool.name, description: tool.description, input_schema: tool.input_schema }
    end
  end

  def step_capture_tools
    @step_capture_tools ||= Ai::StepCaptureTool.schemas_for(@department.playbook)
  end

  # Sempre disponíveis (não dependem de configuração por department) — o modelo controla o avanço da
  # etapa e pode encerrar/transferir a qualquer momento, seguindo as regras do system_prompt acima.
  def control_tools
    [
      { name: ADVANCE_STEP_TOOL,
        description: 'Avança para a próxima etapa do atendimento. Use quando a etapa atual estiver ' \
                     'concluída, ou quando o cliente recusar um dado opcional — nunca force, avance com empatia.',
        input_schema: { type: 'object', properties: {} } },
      { name: RESOLVE_TOOL,
        description: 'Encerra o atendimento (marca a conversa como resolvida) quando as condições de ' \
                     'encerramento configuradas forem atendidas.',
        input_schema: { type: 'object', properties: {} } },
      { name: TRANSFER_TOOL,
        description: 'Transfere o atendimento para um humano quando as condições de transferência ' \
                     'configuradas forem atendidas, ou quando instruído a transferir imediatamente.',
        input_schema: { type: 'object', properties: {} } }
    ]
  end

  # Leitura PURA do índice server-tracked (Ai::StateManager#current_step) — não roda track_step, não
  # avança nada; só lê o mesmo ai_step_index que o caminho legado também lê. Quem avança é
  # Api::Internal::AiExecuteToolController ao receber uma chamada de "avancar_etapa".
  def current_step
    @current_step ||= Ai::StateManager.new(conversation: @conversation, agent: @agent).current_step(@department)
  end
end
