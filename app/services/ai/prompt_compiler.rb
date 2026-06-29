# Compiles the final system prompt from structured config (identity + playbook + knowledge +
# tools + memory). The user never writes this — they fill structure, we generate the prompt.
class Ai::PromptCompiler
  def self.compile(agent:, department:, knowledge:, memory:, tools:, collected: {})
    parts = []
    parts.concat(identity_lines(agent))
    parts << agent.base_prompt if agent.base_prompt.present?
    parts << "Personalidade: #{agent.assistant_personality}." if agent.assistant_personality.present?
    parts << "Responda no idioma #{agent.assistant_language}." if agent.assistant_language.present?
    parts << "Regras de segurança (nunca viole): #{agent.guardrails}." if agent.guardrails.present?

    parts << "Departamento: #{department.name}. Objetivo: #{department.objetivo}."
    parts << "Instruções: #{department.instructions}." if department.instructions.present?
    if (pb = department.playbook)
      step_lines = step_lines(pb.steps)
      if step_lines.present?
        parts << "Etapas do atendimento:\n#{step_lines.join("\n")}\n" \
                 "Em current_step, informe o nome EXATO da etapa atual do atendimento."
      end
      parts << "Transfira para humano quando: #{Array(pb.transfer_when).join('; ')}." if pb.transfer_when.present?
      parts << "Encerre quando: #{Array(pb.close_when).join('; ')}." if pb.close_when.present?
    end

    lead_vars = department.lead_variables.to_a
    if lead_vars.present?
      lines = lead_vars.map { |v| "- #{v.name} (#{v.var_type})#{v.description.present? ? ": #{v.description}" : ''}" }
      parts << "Procure coletar naturalmente estas informações do cliente:\n#{lines.join("\n")}\n" \
               "Sempre que o cliente informar um destes dados, inclua-o no campo \"attributes\" do JSON " \
               "usando a CHAVE exata do nome acima (ex.: {\"cidade\":\"Maravilha\"}). Não invente — só o que o cliente disse."
    end

    # Dados que já temos deste cliente (atributos do contato). A IA deve USÁ-LOS e NÃO perguntar de
    # novo — só pedir o que ainda falta. Sem isso, ela repergunta o que já foi informado.
    already = (collected || {}).reject { |_k, v| v.to_s.strip.empty? }
    if already.present?
      lines = already.map { |k, v| "- #{k}: #{v}" }
      parts << "Dados JÁ coletados deste cliente (use-os; NÃO pergunte de novo):\n#{lines.join("\n")}"
    end

    if tools.present?
      lines = tools.map { |t| "- #{t.name}: #{t.description} (input: #{t.input_schema.to_json})" }
      parts << "Ferramentas disponíveis (use quando necessário):\n#{lines.join("\n")}"
    end

    targets = handoff_targets(agent)
    if targets.present?
      lines = targets.map { |tg| tg[:hint].present? ? "- #{tg[:name]}: #{tg[:hint]}" : "- #{tg[:name]}" }
      parts << "Você pode transferir para outra IA quando o assunto for melhor atendido por ela. IAs de destino:\n" \
               "#{lines.join("\n")}\nPara transferir, retorne decision \"handoff\" e o nome EXATO da IA em handoff_target."
    end

    parts << "Base de conhecimento relevante:\n#{knowledge.join("\n---\n")}" if knowledge.present?
    parts << "Memória da conversa: #{memory.summary}" if memory&.summary.present?
    parts << response_contract
    parts.join("\n\n")
  end

  # AI agents this agent may hand the conversation to (allowlist by agent id).
  def self.handoff_targets(agent)
    ids = agent.respond_to?(:handoff_agent_ids) ? Array(agent.handoff_agent_ids) : []
    return [] if ids.empty?

    ::Ai::Agent.where(account_id: agent.account_id, id: ids).map do |a|
      { name: (a.assistant_name.presence || a.name).to_s, hint: a.category.to_s.strip.presence }
    end
  rescue StandardError
    []
  end

  # Steps may be the new object form ({name, instructions}) or the legacy string form.
  # Renders one bullet per step: "- Nome: instruções".
  def self.step_lines(steps)
    Array(steps).map do |s|
      if s.is_a?(Hash)
        name = (s['name'] || s[:name]).to_s.strip
        instr = (s['instructions'] || s[:instructions]).to_s.strip
        next if name.blank?

        instr.present? ? "- #{name}: #{instr}" : "- #{name}"
      else
        s.to_s.strip.presence&.then { |line| "- #{line}" }
      end
    end.compact
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
      {"decision":"reply|invoke_tool|handoff|close|noop","reply_text":"texto ao cliente","tool":{"name":"NomeDaFerramenta","input":{}},"handoff_reason":"","handoff_target":"","current_step":"","confidence":0.0,"attributes":{}}
      Em "attributes", coloque os dados coletados do cliente (chave: valor); deixe {} se não houver nada novo.
    TXT
  end
end
