# Compiles the final system prompt from structured config (identity + playbook + knowledge +
# tools + memory). The user never writes this — they fill structure, we generate the prompt.
class Ai::PromptCompiler
  def self.compile(agent:, department:, knowledge:, memory:, tools:)
    parts = []
    parts << "Você é #{agent.assistant_name.presence || agent.name}, assistente virtual da empresa."
    parts << agent.base_prompt if agent.base_prompt.present?
    parts << "Personalidade: #{agent.assistant_personality}." if agent.assistant_personality.present?
    parts << "Responda no idioma #{agent.assistant_language}." if agent.assistant_language.present?
    parts << "Regras de segurança (nunca viole): #{agent.guardrails}." if agent.guardrails.present?

    parts << "Departamento: #{department.name}. Objetivo: #{department.objetivo}."
    if (pb = department.playbook)
      parts << "Etapas do atendimento: #{Array(pb.steps).join(' -> ')}." if pb.steps.present?
      parts << "Transfira para humano quando: #{Array(pb.transfer_when).join('; ')}." if pb.transfer_when.present?
      parts << "Encerre quando: #{Array(pb.close_when).join('; ')}." if pb.close_when.present?
    end

    if tools.present?
      lines = tools.map { |t| "- #{t.name}: #{t.description} (input: #{t.input_schema.to_json})" }
      parts << "Ferramentas disponíveis (use quando necessário):\n#{lines.join("\n")}"
    end

    parts << "Base de conhecimento relevante:\n#{knowledge.join("\n---\n")}" if knowledge.present?
    parts << "Memória da conversa: #{memory.summary}" if memory&.summary.present?
    parts << response_contract
    parts.join("\n\n")
  end

  def self.response_contract
    <<~TXT.strip
      Decida a próxima ação. Retorne ESTRITAMENTE um JSON válido, sem texto fora dele:
      {"decision":"reply|invoke_tool|handoff|close|noop","reply_text":"texto ao cliente","tool":{"name":"NomeDaFerramenta","input":{}},"handoff_reason":"","confidence":0.0}
    TXT
  end
end
