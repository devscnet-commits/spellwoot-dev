# Turns a KNOWN attribute key into an OpenAI function-calling tool schema ("registrar_<attribute>"),
# so the Python orchestrator path captures structured data via a tool call instead of the
# text-instruction prompt the legacy decide()/call_with_tools() path uses.
#
# Deliberately NOT tied to any single step's `collect` field (achado ao vivo): the admin's step
# INSTRUCTIONS are free text ("Colete CPF, email e telefone"), but `collect` is a single dropdown —
# one attribute per step. A step whose text asks for 3 things but whose collect only names 1 gave
# the model an instruction with no "button" for the other 2 — it had no registrar_email/
# registrar_telefone tool to call, so it hallucinated "problema técnico" instead. Fix: generate a
# tool for EVERY key in Ai::StateManager#known_slot_keys (steps' collect ∪ department.lead_variables
# ∪ the account's CustomAttributeDefinition catalog — the SAME union the legacy path already uses
# for its asked_slot contract), not just the current (or any single) step's collect. When a key IS
# also declared via some step's collect, that step's type/options build a more precise JSON Schema
# property; otherwise it falls back to a generic string.
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

  # One schema per key in `attribute_keys` (Ai::StateManager#known_slot_keys — the full catalog, not
  # any one step's collect). playbook is used ONLY to look up a more precise type/options when some
  # step happens to declare that same attribute via collect; a playbook-less department (or a key no
  # step ever declares) still gets a schema, just a generic string property.
  def schemas_for(playbook, attribute_keys)
    step_by_attribute = Array(playbook&.steps).each_with_object({}) do |step, acc|
      attribute = Ai::StepSlot.attribute(step)
      acc[attribute] ||= step if attribute.present?
    end

    Array(attribute_keys).uniq.map { |attribute| build_schema(attribute, step_by_attribute[attribute]) }
  end

  # {name:, description:, input_schema:} for one attribute key. `step` (optional) supplies
  # type/options when that attribute happens to be declared via some step's collect; nil ->
  # generic string property. Same shape Ai::PythonOrchestratorClient already sends for
  # Ai::Tool-backed tools, so no change needed on the Python side to consume this.
  def build_schema(attribute, step = nil)
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
    return { type: 'string' } unless step

    options = Ai::StepSlot.options(step)
    return { type: 'string', enum: options } if options.present?

    { type: Ai::StepSlot.type(step) == 'number' ? 'number' : 'string' }
  end
end
