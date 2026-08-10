# Turns a playbook step's declared `collect` slot (Ai::StepSlot) into an OpenAI function-calling
# tool schema, so the Python orchestrator path captures structured data via a tool call instead of
# the text-instruction prompt the legacy decide()/call_with_tools() path uses. Ai::StepSlot stays
# the single source of truth for what a step's collect means — this module only reshapes it for
# the wire, both when Ai::PythonOrchestratorClient builds tools_schema and when
# Api::Internal::AiExecuteToolController receives a callback and needs to recognize one of these
# tool names as a capture (not a real Ai::Tool record — no CapabilityExecution audit row for these).
module Ai::StepCaptureTool
  PREFIX = 'registrar_'

  module_function

  def tool_name(attribute)
    "#{PREFIX}#{attribute}"
  end

  # nil when tool_name doesn't match a capture tool at all (a real Ai::Tool's name instead).
  def attribute_for(tool_name)
    name = tool_name.to_s
    name.start_with?(PREFIX) ? name.delete_prefix(PREFIX).presence : nil
  end

  # One schema per DISTINCT attribute declared across the playbook's steps — several steps can
  # declare the same attribute (revisited later in the flow); OpenAI needs unique function names
  # per request, so dedup by attribute, not by step. {name:, description:, input_schema:} — the
  # SAME shape Ai::PythonOrchestratorClient already sends for Ai::Tool-backed tools, so no change
  # needed on the Python side to consume these.
  def schemas_for(playbook)
    return [] unless playbook

    Array(playbook.steps).filter_map { |step| build_schema(step) }.uniq { |schema| schema[:name] }
  end

  def build_schema(step)
    attribute = Ai::StepSlot.attribute(step)
    return nil if attribute.blank?

    {
      name: tool_name(attribute),
      description: "Registra o dado \"#{attribute}\" assim que o cliente informar — mesmo que ele " \
                   'adiante esse dado junto de outros, fora de ordem, na mesma mensagem.',
      input_schema: {
        type: 'object',
        properties: { attribute => property_schema(step) },
        required: [attribute]
      }
    }
  end

  def property_schema(step)
    options = Ai::StepSlot.options(step)
    return { type: 'string', enum: options } if options.present?

    { type: Ai::StepSlot.type(step) == 'number' ? 'number' : 'string' }
  end
end
