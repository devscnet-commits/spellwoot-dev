# Adapts a persisted Ai::Tool record to the RubyLLM::Tool interface so the model can use
# the native tool_use/tool_result loop (Chat Completions) instead of a second text-injected
# API call. Works for every provider ruby_llm supports: Anthropic sends `input_schema`,
# OpenAI sends `parameters` — both read from params_schema, serialised per-provider by the gem.
#
# Usage (Peça 2/3 — gateway):
#   adapters = Ai::LlmToolAdapter.for_department(department, conversation:, mode:, run:)
#   chat.with_tools(*adapters)
#   response = chat.ask(user_message)
#   executions = adapters.flat_map(&:executions)  # for audit + auto-fill
class Ai::LlmToolAdapter < RubyLLM::Tool
  attr_reader :ai_tool, :executions

  def initialize(ai_tool:, conversation:, mode:, run: nil)
    @ai_tool      = ai_tool
    @conversation = conversation
    @mode         = mode
    @run          = run
    @executions   = []
  end

  # Providers require names matching /[a-zA-Z0-9_-]+/.
  # We derive a stable slug so the model echoes back the exact value we registered.
  # "Consultar viabilidade" → "consultar_viabilidade"
  # "Verificar CPF/CNPJ"   → "verificar_cpf_cnpj"
  def name
    @name ||= self.class.slug(@ai_tool.name, @ai_tool.id)
  end

  def description
    @ai_tool.description.to_s
  end

  # Returns the JSON Schema stored in ai_tools.input_schema directly.
  # The frontend always writes { type:'object', properties:{…}, required:[…] } — the exact
  # format Anthropic expects as input_schema and OpenAI expects as parameters.
  # nil → provider falls back to an empty-object schema (tool with no required arguments).
  def params_schema
    schema = @ai_tool.input_schema
    return nil if schema.blank?

    schema.is_a?(String) ? JSON.parse(schema) : schema
  rescue JSON::ParserError
    nil
  end

  # Called by RubyLLM::Chat#handle_tool_calls after the model emits a tool_use/function_call block.
  # Arguments arrive with symbol keys (Chat#execute_tool does transform_keys(:to_sym)).
  # The return value becomes the tool_result content sent to the model in the next turn.
  def execute(**args)
    execution = Ai::ToolExecutor.new(
      tool:         @ai_tool,
      input:        args.stringify_keys,
      conversation: @conversation,
      mode:         @mode,
      run:          @run
    ).perform

    @executions << execution

    if execution.status == 'executed'
      execution.output.to_json
    else
      { 'status' => execution.status, 'reason' => execution.output['reason'] }.to_json
    end
  end

  # Builds one adapter per active tool in a department — the factory used by the gateway.
  def self.for_department(department, conversation:, mode:, run: nil)
    department.tools.active.map do |ai_tool|
      new(ai_tool: ai_tool, conversation: conversation, mode: mode, run: run)
    end
  end

  # Stable, provider-safe slug derived from the record name.
  # Removes diacritics, replaces non-alphanumeric chars with underscores, collapses runs,
  # strips leading/trailing underscores. Falls back to "tool_<id>" if the result is blank.
  def self.slug(raw, id)
    raw.to_s
       .unicode_normalize(:nfkd)
       .encode('ASCII', invalid: :replace, undef: :replace, replace: '')
       .gsub(/[^a-zA-Z0-9_-]/, '_')
       .gsub(/_+/, '_')
       .gsub(/\A_+|_+\z/, '')
       .downcase
       .presence || "tool_#{id}"
  end
end
