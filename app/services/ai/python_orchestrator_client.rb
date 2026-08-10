# Bridges Ai::Gateway to the Python AI orchestrator microservice, which owns the OpenAI Responses
# API reasoning/tool-call loop for a turn (native OpenAI tools like file_search resolved entirely
# in Python; Rails-side tools proxied back via Api::Internal::AiExecuteToolController). Replaces
# Ai::ContextBuilder + Ai::ModelRouter for departments opted into this path — Gateway keeps billing,
# department resolution and final delivery (Ai::ActionDispatcher) exactly as before.
#
# History: no flattened message blob is sent. previous_response_id (reused from the SAME
# conversation.additional_attributes['openai_conversation_id'] field the existing decide()/
# call_with_tools() paths already read/write) lets OpenAI keep the full turn history server-side.
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

  def self.process_message(conversation:, content:, agent:, department:, mode:)
    new(conversation: conversation, content: content, agent: agent, department: department, mode: mode).perform
  end

  def initialize(conversation:, content:, agent:, department:, mode:)
    @conversation = conversation
    @content = content
    @agent = agent
    @department = department
    @mode = mode
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
      previous_response_id: @conversation.additional_attributes&.dig('openai_conversation_id'),
      # Multi-tenant: cada Account escolhe seu próprio modelo/temperatura via Ai::OperationProfile
      # (tela de admin). nil quando o agente não tem perfil — o orquestrador cai no OPENAI_MODEL do
      # seu próprio .env e deixa a OpenAI usar o default de temperatura, não hardcodeia nada aqui.
      model: operation_profile&.supervisor_model,
      temperature: temperature
    }
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

  # Trimmed identity/persona prompt (no playbook step INSTRUCTIONS text — this path doesn't run
  # Ai::StateManager#track_step, so anchoring the model to a step it never advances would mislead it).
  # What DOES come from the playbook is the "registrar_*" capture tools below — flow-control text
  # replaced by function calls, not by more prompt.
  def system_prompt
    lines = []
    lines << "Você é #{@agent.assistant_name.presence || @agent.name}."
    lines << @agent.base_prompt if @agent.base_prompt.present?
    lines << "Personalidade: #{@agent.assistant_personality}." if @agent.assistant_personality.present?
    lines << "Responda no idioma #{@agent.assistant_language}." if @agent.assistant_language.present?
    lines << "Regras de segurança (nunca viole): #{@agent.guardrails}." if @agent.guardrails.present?
    lines << "Departamento: #{@department.name}. Objetivo: #{@department.objetivo}."
    lines << capture_tools_instruction if step_capture_tools.present?
    lines.join("\n")
  end

  # Generic (step-agnostic) instruction covering EVERY "registrar_*" tool at once — not one paragraph
  # per step. Explicitly allows calling more than one in the same turn: a customer who front-loads
  # several answers (e.g. name + address in message 1) must not be forced to repeat them one at a
  # time just because a single "current step" gate would only accept one call per turn.
  def capture_tools_instruction
    'Use as ferramentas "registrar_*" para gravar cada dado assim que o cliente informar, na ordem ' \
      'em que ele fornecer — pode chamar mais de uma na mesma resposta se ele adiantar vários dados ' \
      'de uma vez. Nunca peça de novo um dado que o cliente já informou nesta conversa.'
  end

  # Real Ai::Tool-backed tools (webhooks/capabilities/integrations, unchanged) + one function-calling
  # tool per attribute the playbook's steps declare via `collect` (Ai::StepCaptureTool) — replaces the
  # old "Etapas do atendimento" text block from Ai::PromptCompiler. A capture tool losing to a
  # same-named REAL tool (name collision) is intentional: the configured tool wins.
  def tools_schema
    real_names = real_tools.map { |t| t[:name] }
    real_tools + step_capture_tools.reject { |t| real_names.include?(t[:name]) }
  end

  def real_tools
    @real_tools ||= @department.tools.active.map do |tool|
      { name: tool.name, description: tool.description, input_schema: tool.input_schema }
    end
  end

  def step_capture_tools
    @step_capture_tools ||= Ai::StepCaptureTool.schemas_for(@department.playbook)
  end
end
