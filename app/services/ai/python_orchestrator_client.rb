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
# Per-turn scope (deliberate, not the "send everything" shape this class had earlier): system_prompt
# carries the agent's base persona + ONLY the CURRENT step's instructions text (read the same way
# Ai::PromptCompiler's step anchor does — server-tracked ai_step_index, never all steps at once), and
# tools_schema carries the department's real tools + ONLY the current step's capture tool (Ai::StepCaptureTool),
# not one per step. The step's `instructions` text stays a first-class, always-visible field (Python
# reads it) — it is NOT being replaced by function-calling; only the OLD "dump every step's tool at
# once" shape was.
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

  def self.process_message(conversation:, content:, agent:, department:, mode:, message: nil)
    new(conversation: conversation, content: content, agent: agent, department: department, mode: mode,
        message: message).perform
  end

  def initialize(conversation:, content:, agent:, department:, mode:, message: nil)
    @conversation = conversation
    @content = content
    @agent = agent
    @department = department
    @mode = mode
    @message = message
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

  # Persona geral do agente + a instrução da ETAPA ATUAL (server-tracked ai_step_index, mesma leitura
  # pura de Ai::StateManager#current_step — nunca avança nada aqui). Nunca as etapas todas juntas.
  def system_prompt
    lines = []
    lines << "Você é #{@agent.assistant_name.presence || @agent.name}."
    lines << @agent.base_prompt if @agent.base_prompt.present?
    lines << "Personalidade: #{@agent.assistant_personality}." if @agent.assistant_personality.present?
    lines << "Responda no idioma #{@agent.assistant_language}." if @agent.assistant_language.present?
    lines << "Regras de segurança (nunca viole): #{@agent.guardrails}." if @agent.guardrails.present?
    lines << "Departamento: #{@department.name}. Objetivo: #{@department.objetivo}."
    lines << "Etapa atual: #{current_step_instructions}" if current_step_instructions.present?
    lines.join("\n")
  end

  def current_step_instructions
    return nil unless current_step.is_a?(Hash)

    (current_step['instructions'] || current_step[:instructions]).to_s.strip.presence
  end

  # Tools reais do department (webhooks/capabilities/integrations, inalteradas) + a tool de captura
  # (Ai::StepCaptureTool) SÓ da etapa atual — não uma por etapa do playbook inteiro.
  def tools_schema
    tool = step_capture_tool
    return real_tools if tool.nil? || real_tools.any? { |t| t[:name] == tool[:name] }

    real_tools + [tool]
  end

  def real_tools
    @real_tools ||= @department.tools.active.map do |tool|
      { name: tool.name, description: tool.description, input_schema: tool.input_schema }
    end
  end

  def step_capture_tool
    Ai::StepCaptureTool.build_schema(current_step)
  end

  # Leitura PURA do índice server-tracked (Ai::StateManager#current_step) — não roda track_step, não
  # avança nada; só lê o mesmo ai_step_index que o caminho legado também lê.
  def current_step
    @current_step ||= Ai::StateManager.new(conversation: @conversation, agent: @agent).current_step(@department)
  end
end
