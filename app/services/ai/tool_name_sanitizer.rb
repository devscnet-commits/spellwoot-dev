# OpenAI function-calling names must match ^[a-zA-Z0-9_-]+$ — Ai::CapabilityRegistry's whole
# convention is dotted keys (conversation.resolve, conversation.add_label, contact.update_attributes,
# ...) and an admin-typed Ai::Tool#name has no format validation at all, so either can 400 the
# OpenAI call ("Invalid 'tools[N].name': string does not match pattern"). This is a general
# translation layer, not a one-tool patch: Ai::PythonOrchestratorClient sanitizes EVERY real tool
# name (and the two control tool constants) the same way before they reach tools_schema;
# Api::Internal::AiExecuteToolController reverses it by recomputing #sanitize over the small known
# candidate set for that turn (department.tools.active names + the control constants) and matching
# — NOT by guessing "_" always meant "." (ambiguous: a literal underscore and a sanitized dot are
# indistinguishable in the output alone).
module Ai::ToolNameSanitizer
  module_function

  def sanitize(name)
    name.to_s.gsub(/[^a-zA-Z0-9_-]/, '_')
  end

  # Recovers the ORIGINAL name from a sanitized one by checking which of `candidates` sanitizes to
  # the same string. Unambiguous as long as no two candidates collide after sanitizing (not
  # currently guarded — see class comment). No match (name was already safe, or genuinely unknown)
  # -> returns sanitized_name unchanged, same as today's behavior for an unrecognized tool.
  def resolve(sanitized_name, candidates)
    candidates.find { |candidate| sanitize(candidate) == sanitized_name } || sanitized_name
  end
end
