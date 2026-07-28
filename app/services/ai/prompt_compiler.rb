# Compiles the final system prompt from structured config (identity + playbook + knowledge +
# tools + memory). The user never writes this — they fill structure, we generate the prompt.
class Ai::PromptCompiler
  # followup: true monta o prompt ENXUTO da 2ª chamada (Ai::Gateway#tool_followup) — a ferramenta já
  # executou, então o modelo só REDIGE a resposta (pode pedir handoff/close) sem avançar etapa, gravar
  # attributes ou chamar outra ferramenta. SAEM a LISTA completa das etapas, lead_variables,
  # fillable_attributes, definições de ferramentas e transfer_when/close_when. FICAM (além de persona,
  # RAG +anti-invenção, times de handoff, memória e contrato) a ÂNCORA da etapa corrente e o ESTADO DA
  # COLETA ("JÁ TENHO"/"FALTA agora"): sem eles o followup redige sem saber a etapa nem o que já foi
  # coletado e repergunta/pede dado de outra etapa (conv 372). false (default) = prompt COMPLETO (todos os
  # blocos). Em AMBOS os modos a ordem é FIXO-primeiro, VARIÁVEL-depois (prompt caching): o conjunto de
  # blocos de cada modo é o mesmo de antes — só a ordem mudou.
  def self.compile(agent:, department:, knowledge:, memory:, tools:, collected: {}, fillable_attributes: [],
                   customer_memory: nil, step_index: nil, followup: false)
    # PROMPT CACHING: prefixo FIXO (igual entre turnos) primeiro, blocos VARIÁVEIS (mudam por turno)
    # depois. O cache de prefixo do provider exige que tudo que muda venha DEPOIS de tudo que é estável —
    # por isso o response_contract (fixo) subiu para o fim da seção fixa, e âncora/estado/RAG/memória
    # (variáveis) foram para o fim. Mesmo CONJUNTO de blocos de antes; só a ordem mudou.
    fixed = []
    fixed.concat(identity_lines(agent))
    fixed << agent.base_prompt if agent.base_prompt.present?
    fixed << "Personalidade: #{agent.assistant_personality}." if agent.assistant_personality.present?
    fixed << "Responda no idioma #{agent.assistant_language}." if agent.assistant_language.present?
    fixed << "Regras de segurança (nunca viole): #{agent.guardrails}." if agent.guardrails.present?

    fixed << "Departamento: #{department.name}. Objetivo: #{department.objetivo}."
    # NÃO injetar `department.instructions`: coluna legada, sem editor na UI (comportamento é montado
    # por objetivo + steps do playbook). Ficava como ruído órfão no prompt. Coluna mantida no schema
    # (aposentada só a leitura) — cleanup de schema é débito separado.
    #
    # LISTA das etapas + transfer/close: FIXO, só no prompt completo (não no followup). A ÂNCORA da etapa
    # NÃO entra aqui — muda por turno, então é VARIÁVEL e vai para a seção variável (senão quebra o prefixo).
    if !followup && (pb = department.playbook)
      step_lines = step_lines(pb.steps)
      fixed << "Etapas do atendimento (na ordem):\n#{step_lines.join("\n")}" if step_lines.present?
      fixed << "Transfira para humano quando: #{Array(pb.transfer_when).join('; ')}." if pb.transfer_when.present?
      fixed << "Encerre quando: #{Array(pb.close_when).join('; ')}." if pb.close_when.present?
    end

    lead_vars = followup ? [] : department.lead_variables.to_a
    if lead_vars.present?
      lines = lead_vars.map { |v| "- #{v.name} (#{v.var_type})#{v.description.present? ? ": #{v.description}" : ''}" }
      fixed << "Procure coletar naturalmente estas informações do cliente:\n#{lines.join("\n")}\n" \
               "Sempre que o cliente informar um destes dados, inclua-o no campo \"attributes\" do JSON " \
               "usando a CHAVE exata do nome acima (ex.: {\"cidade\":\"Maravilha\"}). Não invente — só o que o cliente disse."
    end

    # Atributos personalizados da conversa que a IA pode preencher (chave + rótulo). A IA deve
    # devolvê-los em "attributes" usando a CHAVE exata quando o cliente informar o dado.
    if !followup && fillable_attributes.present?
      lines = fillable_attributes.map { |key, label| "- #{key}#{label.present? ? " (#{label})" : ''}" }
      fixed << "Atributos da conversa para preencher quando o cliente informar (use a CHAVE exata em \"attributes\", ex.: {\"cidade\":\"Maravilha\"}):\n#{lines.join("\n")}"
    end

    if !followup && tools.present?
      lines = tools.map { |t| "- #{t.name}: #{t.description} (input: #{t.input_schema.to_json})" }
      fixed << "Ferramentas disponíveis (use quando necessário):\n#{lines.join("\n")}"
    end

    human_teams = ::Team.where(account_id: agent.account_id).order(:name).pluck(:name)
    if human_teams.present?
      lines = human_teams.map { |t| "- #{t}" }
      fixed << "Para transferir para um ATENDENTE HUMANO, NÃO apenas escreva no texto: retorne decision " \
               "\"handoff\" e o nome EXATO do time em handoff_target. Times disponíveis:\n#{lines.join("\n")}"
    end

    targets = handoff_targets(agent)
    if targets.present?
      lines = targets.map { |tg| tg[:hint].present? ? "- #{tg[:name]}: #{tg[:hint]}" : "- #{tg[:name]}" }
      fixed << "Você pode transferir para outra IA quando o assunto for melhor atendido por ela. IAs de destino:\n" \
               "#{lines.join("\n")}\nPara transferir, retorne decision \"handoff\" e o nome EXATO da IA em handoff_target."
    end

    # response_contract é FIXO -> encerra o prefixo cacheável (era o ÚLTIMO de tudo). Tudo que muda por
    # turno vem DEPOIS dele.
    fixed << response_contract

    # ===== Blocos VARIÁVEIS (mudam por turno) — depois do prefixo fixo, para habilitar prompt caching =====
    variable = []
    # Âncora da etapa corrente: SEPARADA do bloco de etapas (antes vinha concatenada dentro dele, o que
    # injetava conteúdo variável num bloco fixo grande e quebrava o prefixo). Vale para completo e followup.
    if (pb = department.playbook)
      anchor = current_step_line(pb.steps, step_index)
      variable << anchor if anchor
    end

    # Estado da coleta (reforço ATIVO por turno): o que já temos + o slot que a etapa ATUAL ainda precisa.
    # Montado pelo CÓDIGO (não pelo modelo) — mata a repergunta em etapa de vários turnos. Presente também
    # no followup (#273/#278: sem ele o followup repergunta o já coletado).
    already = (collected || {}).reject { |_k, v| v.to_s.strip.empty? }
    state_block = collection_state_block(department.playbook&.steps, step_index, already)
    variable << state_block if state_block

    if knowledge.present?
      variable << "Base de conhecimento relevante:\n#{knowledge.join("\n---\n")}\n\n" \
                  "Use APENAS os produtos, planos, valores e informações citados acima. " \
                  "NUNCA invente nome de produto, valor, característica ou promoção que não esteja " \
                  "literalmente neste bloco. Se a informação pedida não estiver aqui, diga que vai " \
                  "verificar ou transfira para um humano — não improvise."
    end
    variable << "Memória da conversa: #{memory.summary}" if memory&.summary.present?
    variable.concat(customer_memory_lines(customer_memory))

    (fixed + variable).join("\n\n")
  end

  # ESTADO DA COLETA — reforço ATIVO, remontado deterministicamente pelo código a cada turno (não pelo
  # modelo). O modelo tende a ignorar contexto passivo após alguns turnos; precisa ser LEMBRADO
  # ativamente. "JÁ TENHO" = fatos já coletados (não reperguntar). "FALTA agora" = o slot da etapa
  # ATUAL, se ainda não preenchido — diz exatamente qual dado pedir e com QUE chave salvar (a mesma que
  # o Ai::StateManager usa para destravar a etapa). Substitui o antigo bloco "Dados JÁ coletados".
  def self.collection_state_block(steps, step_index, already)
    slot = pending_slot(steps, step_index, already)
    return nil if already.blank? && slot.nil?

    lines = ['ESTADO DA COLETA (mantido pelo sistema — NÃO repita o que já está aqui):']
    # Gap 1: mapeia o token de ausência p/ o rótulo legível — o modelo NUNCA vê o token cru (não pode
    # ecoá-lo ao cliente); "não informado" comunica que o dado foi declinado, sem reperguntar.
    lines << "✓ JÁ TENHO: #{already.map { |k, v| "#{k}=#{Ai::StepSlot.display(v)}" }.join(', ')}" if already.present?
    lines << "◦ FALTA agora (peça este dado e salve em \"attributes\" com a CHAVE exata): #{slot}" if slot
    # Gap 1 (recomendação A): dá ao modelo a sentinela para quando o cliente declinar o dado do slot.
    if slot
      lines << "Se o cliente disser que NÃO TEM esse dado ou não quer informar, devolva em \"attributes\" " \
               "a chave #{slot} com o valor EXATO #{Ai::StepSlot::ABSENT} (não invente um valor)."
    end
    lines << 'REGRA: NUNCA peça de novo um dado da lista "JÁ TENHO" — use o valor e siga. Se o cliente ' \
             'já respondeu o que esta etapa pede, registre em "attributes" e não repita a mesma pergunta.'
    lines << 'Se o valor que o cliente enviar parecer incompleto/estranho para o dado pedido, confirme ' \
             'UMA única vez mostrando o que recebeu ("Recebi \'X\', está correto assim?"). Se ele ' \
             'corrigir, use o valor corrigido; se confirmar, repetir ou insistir, ACEITE como veio e ' \
             'siga — NUNCA peça o mesmo dado uma terceira vez.'
    lines.join("\n")
  end

  # Chave do slot que a etapa ATUAL coleta e que AINDA não temos. nil quando a etapa não declara slot
  # (collect.attribute) ou o dado já foi coletado. Espelha a leitura do Ai::StateManager (fonte única
  # do avanço) para o prompt pedir exatamente a chave que conclui a etapa.
  def self.pending_slot(steps, step_index, already)
    list = Array(steps)
    return nil if list.empty?

    key = Ai::StepSlot.attribute(list[step_index.to_i.clamp(0, list.size - 1)])
    return nil if key.nil? || (already || {}).key?(key)

    key
  end

  # Persistent memory of THIS contact, built from past conversations (Ai::CustomerMemory). Reuse it
  # and do NOT re-ask what is already known — same intent as the "Dados JÁ coletados" block, but
  # spanning conversations. Returns [] when there is no memory yet.
  def self.customer_memory_lines(customer_memory)
    return [] if customer_memory.nil?

    facts = customer_memory.key_facts.to_h
    return [] if customer_memory.summary.blank? && facts.blank?

    lines = ['Memória do cliente (de conversas anteriores — use e NÃO pergunte de novo o que já souber):']
    lines << "Resumo: #{customer_memory.summary}" if customer_memory.summary.present?
    lines.concat(facts.map { |k, v| "- #{k}: #{v}" }) if facts.present?
    [lines.join("\n")]
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

  # Âncora determinística: informa ao modelo em QUAL etapa ele está, pelo índice rastreado pelo
  # servidor (Ai::StateManager) — não deixa o modelo se autolocalizar (que o fazia retroceder).
  # Indexa o MESMO array que o StateManager (Array(playbook.steps)) para o índice bater. nil => 0.
  # Retorna nil quando não há etapas.
  def self.current_step_line(steps, step_index)
    list = Array(steps)
    return nil if list.empty?

    idx = step_index.to_i.clamp(0, list.size - 1)
    name = step_name_of(list[idx])
    label = name.present? ? "#{idx + 1} de #{list.size} — \"#{name}\"" : "#{idx + 1} de #{list.size}"
    "ETAPA ATUAL (definida pelo sistema, não por você): #{label}. Trabalhe SOMENTE nesta etapa " \
      'agora; NÃO volte a etapas anteriores nem pule adiante — o sistema avança automaticamente ' \
      'quando você sinalizar step_completed. Dados de etapas passadas já aparecem em "Dados já coletados".'
  end

  def self.step_name_of(step)
    step.is_a?(Hash) ? (step['name'] || step[:name]).to_s.strip : step.to_s.strip
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
               'Aja como um atendente humano da equipe. Não diga que é uma inteligência artificial. ' \
                 'Quando a resposta tiver mais de uma ideia ou ficar longa, escreva como uma pessoa real ' \
                 'digitando: separe em mensagens curtas com uma LINHA EM BRANCO entre elas (dois \n) no ' \
                 'campo reply_text. Se for algo curto, responda em uma mensagem só, sem quebrar à força.'
             end
    lines
  end

  def self.response_contract
    <<~TXT.strip
      Decida a próxima ação. Retorne ESTRITAMENTE um JSON válido, sem texto fora dele:
      {"decision":"reply|invoke_tool|handoff|close|noop","reply_text":"texto ao cliente","tool_name":"","tool_input_json":"{}","handoff_reason":"","handoff_target":"","current_step":"","step_completed":false,"asked_slot":"","confidence":0.0,"attributes_list":[]}
      O campo "decision" aceita SOMENTE um destes 5 valores: reply, invoke_tool, handoff, close, noop. NÃO invente outros (ex.: "text", "message", "resposta"). Para responder ao cliente use SEMPRE "reply".
      A etapa atual é DEFINIDA PELO SISTEMA (ver "ETAPA ATUAL" acima) — você NÃO escolhe nem muda de etapa. Em "current_step", apenas repita o nome dessa etapa atual como CONFIRMAÇÃO/registro (é só log; não decide o avanço). Em "step_completed", responda true SOMENTE no turno em que CONCLUIR essa etapa (já obteve tudo que ela exigia); nesse momento o SISTEMA avança sozinho para a próxima. Nos demais turnos, responda false. Nunca volte para uma etapa anterior por conta própria.
      Para chamar uma ferramenta, preencha "tool_name" com o nome EXATO e "tool_input_json" com o input como STRING JSON (um objeto); sem ferramenta, "tool_name" vazio e "tool_input_json" igual a "{}".
      Em "attributes_list", liste os dados coletados do cliente como itens {"key":"chave","value":"valor"}; use [] se não houver nada novo.
      Em "asked_slot", informe o slot que a sua reply_text está pedindo neste turno; vazio se não pede dado.
    TXT
  end
end
