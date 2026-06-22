# Compiles the final system prompt from structured config (identity + playbook + knowledge +
# tools + memory). The user never writes this — they fill structure, we generate the prompt.
class Ai::PromptCompiler
  def self.compile(agent:, department:, knowledge:, memory:, tools:)
    parts = []
    parts.concat(identity_lines(agent))
    parts << agent.base_prompt if agent.base_prompt.present?
    parts << "Personalidade: #{agent.assistant_personality}." if agent.assistant_personality.present?
    parts << "Responda no idioma #{agent.assistant_language}." if agent.assistant_language.present?
    parts << "Regras de segurança (nunca viole): #{agent.guardrails}." if agent.guardrails.present?

    parts << "Departamento: #{department.name}. Objetivo: #{department.objetivo}."
    parts << "Instruções: #{department.instructions}." if department.instructions.present?
    if (pb = department.playbook)
      parts << "Etapas do atendimento: #{Array(pb.steps).join(' -> ')}." if pb.steps.present?
      parts << "Transfira para humano quando: #{Array(pb.transfer_when).join('; ')}." if pb.transfer_when.present?
      parts << "Encerre quando: #{Array(pb.close_when).join('; ')}." if pb.close_when.present?
    end

    lead_vars = department.lead_variables.to_a
    if lead_vars.present?
      lines = lead_vars.map { |v| "- #{v.name} (#{v.var_type})#{v.description.present? ? ": #{v.description}" : ''}" }
      parts << "Procure coletar naturalmente estas informações do cliente:\n#{lines.join("\n")}"
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

  # Identity block: name, company, how it should present itself (human vs IA).
  def self.identity_lines(agent)
    name = agent.assistant_name.presence || agent.name
    company = "da empresa #{agent.company_name}" if agent.company_name.present?
    lines = ["Você é #{[name, company].compact.join(' ')}.".squeeze(' ')]
    lines << "Site da empresa: #{agent.site}." if agent.site.present?
    lines << if agent.identify_as == 'ai'
               'Você é um assistente virtual (IA) e pode assumir isso se perguntarem.'
             else
               'Aja como um atendente humano da equipe. Não diga que é uma inteligência artificial.'
             end
    lines
  end

  def self.response_contract
    <<~TXT.strip
      Decida a próxima ação. Retorne ESTRITAMENTE um JSON válido, sem texto fora dele:
      {"decision":"reply|invoke_tool|handoff|close|noop","reply_text":"texto ao cliente","tool":{"name":"NomeDaFerramenta","input":{}},"handoff_reason":"","confidence":0.0}
    TXT
  end
end
