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
  ORCHESTRATOR_URL = ENV.fetch('AI_ORCHESTRATOR_URL', 'http://localhost:8000/process')
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
      # Sent as strings: the orchestrator's Pydantic request model types both ids as `str`.
      ticket_id: @conversation.id.to_s,
      ai_department_id: @department.id.to_s,
      mode: @mode,
      system_prompt: system_prompt,
      tools_schema: tools_schema,
      vector_store_id: @department.behavior.to_h['vector_store_id'],
      user_input: @content.to_s,
      previous_response_id: @conversation.additional_attributes&.dig('openai_conversation_id')
    }
  end

  # Trimmed identity/persona prompt (no playbook steps/slots — this path doesn't run
  # Ai::StateManager#track_step, so anchoring the model to a step it never advances would mislead it).
  def system_prompt
    lines = []
    lines << "Você é #{@agent.assistant_name.presence || @agent.name}."
    lines << @agent.base_prompt if @agent.base_prompt.present?
    lines << "Personalidade: #{@agent.assistant_personality}." if @agent.assistant_personality.present?
    lines << "Responda no idioma #{@agent.assistant_language}." if @agent.assistant_language.present?
    lines << "Regras de segurança (nunca viole): #{@agent.guardrails}." if @agent.guardrails.present?
    lines << "Departamento: #{@department.name}. Objetivo: #{@department.objetivo}."
    lines.join("\n")
  end

  def tools_schema
    @department.tools.active.map do |tool|
      { name: tool.name, description: tool.description, input_schema: tool.input_schema }
    end
  end
end
