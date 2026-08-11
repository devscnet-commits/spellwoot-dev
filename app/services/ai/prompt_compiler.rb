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
                   customer_memory: nil, step_index: nil, followup: false, knowledge_gap: false,
                   slot_feedback: {}, native_tools: false)
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

    # native_tools: ferramentas são registradas como function definitions no payload da API —
    # não precisam (e não devem) aparecer no prompt. invoke_tool também é suprimido do contrato.
    if !followup && !native_tools && tools.present?
      lines = tools.map { |t| "- #{t.name}: #{t.description} (input: #{t.input_schema.to_json})" }
      fixed << "Ferramentas disponíveis (use quando necessário):\n#{lines.join("\n")}"
    end

    human_teams = human_handoff_teams(agent)
    if human_teams.present?
      lines = human_teams.map do |t|
        desc = t.description.to_s.strip
        desc.present? ? "- #{t.name}: #{desc}" : "- #{t.name}"
      end
      fixed << "Para transferir para um ATENDENTE HUMANO, NÃO apenas escreva no texto: retorne decision " \
               "\"handoff\" e o nome EXATO do time em handoff_target (copie como está na lista; NUNCA " \
               "uma categoria genérica como \"suporte\" ou \"comercial\"). Times disponíveis:\n#{lines.join("\n")}"
    end

    targets = handoff_targets(agent)
    if targets.present?
      lines = targets.map { |tg| tg[:hint].present? ? "- #{tg[:name]}: #{tg[:hint]}" : "- #{tg[:name]}" }
      fixed << "Você pode transferir para outra IA quando o assunto for melhor atendido por ela. IAs de destino:\n" \
               "#{lines.join("\n")}\nPara transferir, retorne decision \"handoff\" e o nome EXATO da IA em " \
               "handoff_target (copie como está na lista; NUNCA invente um nome ou use termos genéricos)."
    end

    # response_contract é FIXO -> encerra o prefixo cacheável (era o ÚLTIMO de tudo). Tudo que muda por
    # turno vem DEPOIS dele.
    fixed << response_contract(native_tools: native_tools)

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
    state_block = collection_state_block(department.playbook&.steps, step_index, already, customer_memory, slot_feedback)
    variable << state_block if state_block

    if knowledge.present?
      variable << "Base de conhecimento relevante:\n#{knowledge.join("\n---\n")}\n\n" \
                  "Use APENAS os produtos, planos, valores e informações citados acima. " \
                  "NUNCA invente nome de produto, valor, característica ou promoção que não esteja " \
                  "literalmente neste bloco. Se a informação pedida não estiver aqui, diga que vai " \
                  "verificar ou transfira para um humano — não improvise."
    elsif knowledge_gap
      # Guarda determinística (conv 397): a etapa DECLAROU uma fonte de conhecimento e o retrieval voltou
      # VAZIO. O modelo não tem base — não pode afirmar nada sobre o assunto (o pior caso é a falsa
      # cobertura). Reduz, não elimina, a alucinação: impede afirmar SEM fonte; não impede contradizer
      # uma fonte presente.
      variable << 'A FONTE de conhecimento que esta etapa precisa consultar NÃO retornou dados. NÃO ' \
                  'afirme nada sobre esse assunto (você não tem fonte para isso): diga que vai verificar ' \
                  'ou transfira para um humano — nunca invente.'
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
  def self.collection_state_block(steps, step_index, already, customer_memory = nil, slot_feedback = {})
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
    # (4): feedback de rejeição por formato — explica POR QUE o último valor foi barrado (ver método).
    lines.concat(Array(rejection_feedback_line(steps, step_index, slot, slot_feedback)))
    # PR3 (Frente C): pré-preenchimento da memória, SÓ slot de FORMATO (ver memory_prefill_line). Array(nil)=[].
    lines.concat(Array(memory_prefill_line(steps, step_index, slot, customer_memory)))
    # Proposta pendente (contrato): obriga a popular attributes[slot] na confirmação (ver método).
    lines.concat(Array(pending_proposal_line(slot, slot_feedback)))
    lines.concat(confirmation_guidance_lines)
    lines.join("\n")
  end

  # Orientação FIXA de confirmação/correção, extraída do collection_state_block (mantém o método enxuto).
  def self.confirmation_guidance_lines
    [
      # REGRA: separa REPERGUNTA (proativa, proibida) de CORREÇÃO (o cliente inicia, permitida). Sem a 2ª
      # frase, "não repita / use o valor e siga" fazia o modelo tratar um valor de JÁ TENHO como fechado e
      # ignorar a correção de um dado de etapa PASSADA (conv da evidência: attrs={}, zero tentativa). A escrita
      # da correção é aceita pelo gate do StateManager (todo slot declarado é gravável — ver supervisor_expected_keys).
      'REGRA: NUNCA peça de novo um dado da lista "JÁ TENHO" — use o valor e siga. MAS se o cliente CORRIGIR por conta ' \
      'própria um desses valores, devolva em "attributes" a MESMA chave com o novo valor: isso é ATUALIZAÇÃO, não ' \
      'repergunta. Se o cliente já respondeu o que esta etapa pede, registre em "attributes" e não repita a mesma pergunta.',
      # Default (conv 396): valor VÁLIDO -> acuse INLINE, junto do próximo pedido. NUNCA um turno só para
      # confirmar — a confirmação isolada cria um turno sem dado novo, onde o motor se perde (runs 2039→2041:
      # a reply pediu confirmação do endereço, o motor já estava na etapa 8, "esta certo" virou documento_cpf).
      'Ao receber um dado VÁLIDO, acuse-o na MESMA mensagem em que pede o próximo dado — NUNCA faça uma pergunta ' \
      'separada só para confirmar. Ex.: "Recebi o CPF 123.456.789-00. Agora, qual o seu e-mail?".',
      # Exceção (sanity-check preservado): SÓ valor que não valida / truncado / malformado ganha a
      # confirmação ISOLADA, uma única vez.
      'EXCEÇÃO — apenas quando o valor parecer incompleto/estranho/malformado para o dado pedido: ' \
      'confirme UMA única vez, isolada, mostrando o que recebeu ("Recebi \'X\', está correto ' \
      'assim?"). Se ele corrigir, use o corrigido; se confirmar, repetir ou insistir, ACEITE como ' \
      'veio e siga — NUNCA peça o mesmo dado uma terceira vez.'
    ]
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

  # PR3 (Frente C) — PRÉ-PREENCHIMENTO DA MEMÓRIA, SÓ SLOT DE FORMATO. Quando o dado que FALTA é de formato
  # conhecido (cpf/email/phone/number/choice — o gate valida a promoção) e há um valor LEMBRADO deste contato
  # (Ai::CustomerMemory, de atendimentos anteriores), dirige o modelo a PROPOR esse valor e pedir confirmação em
  # vez de perguntar do zero. A PROMOÇÃO em si é do MOTOR (Ai::TurnCapture#substitute_proposed_value + gate),
  # determinística; aqui só se pede a proposta e se instrui a SEMPRE devolver a resposta em "attributes".
  #
  # ►► TEXTO LIVRE É DEFERIDO DE PROPÓSITO — NÃO "esquecido". Leia antes de "consertar" o endereço. ◄◄
  # Endereço e afins (slot 'text' sem formato) NÃO são pré-preenchidos aqui. Motivo: em texto livre um "sim"
  # VALIDA como valor, e o motor gravaria "sim" no lugar do dado (a família text-slot-refusal-becomes-value).
  # Quando esta frente voltar, a promoção de texto livre entra como um JUIZ com STATUS PRÓPRIO (confirmação vs
  # dado novo vs off-topic) — **NUNCA** uma lista de frases em PT ("sim/ok/isso/correto..."). Lista de frases
  # vaza ("claro que não", "sim porque...") e é exatamente o padrão que este projeto já aposentou uma vez (o
  # juiz estruturado substituiu a lista no SlotAbsence). O valor lembrado de texto livre SEGUE visível no bloco
  # customer_memory_lines: o modelo pode mencioná-lo, mas o motor não pré-preenche nem promove.
  def self.memory_prefill_line(steps, step_index, slot, customer_memory)
    return nil if slot.nil? || customer_memory.nil?

    list = Array(steps)
    return nil if list.empty?
    return nil unless format_slot?(list[step_index.to_i.clamp(0, list.size - 1)], slot)

    value = customer_memory.key_facts.to_h[slot].to_s.strip
    return nil if value.blank?

    "DADO LEMBRADO DE ATENDIMENTO ANTERIOR — o dado \"#{slot}\" deste cliente provavelmente é \"#{value}\". " \
      "NÃO pergunte do zero: PROPONHA esse valor e peça UMA confirmação objetiva (ex.: \"Ainda é #{value}?\"). " \
      "Quando o cliente responder, SEMPRE devolva em \"attributes\" a chave #{slot} (o valor que ele disser, ou " \
      'a própria confirmação). Se confirmar, esse valor é aceito; se corrigir, use o novo.'
  end

  # CONTRATO (NÃO orientação de conversa) — dispara quando há PROPOSTA PENDENTE para o slot corrente:
  # ai_last_proposed_value, de QUALQUER origem (memória OU o próprio modelo, ex.: propôs um plano). Sem isto, a
  # confirmação vem MUDA (attributes={}) e Ai::TurnCapture#substitute_proposed_value não tem o que promover
  # (proposal.echo_missing; 12/13 em plano_escolhido — a memory_prefill_line acima só cobre proposta vinda da
  # MEMÓRIA). Dirigido por ESTADO DO MOTOR (a proposta pendente), não por estilo de atendimento -> vive no código.
  # SEM exemplo, SEM "apresente/pergunte": apresentar a opção é da INSTRUÇÃO DA ETAPA (tenant); aqui só a mecânica
  # do canal attributes. A promoção em si é do motor (substitute_proposed_value + gate) — aqui só se exige o ECO.
  def self.pending_proposal_line(slot, slot_feedback)
    return nil if slot.blank?

    proposed = (slot_feedback || {})['pending_proposed'].to_s.strip
    return nil if proposed.blank?

    "PROPOSTA PENDENTE para \"#{slot}\": você propôs um valor e aguarda a resposta do cliente. Quando ele " \
      "responder, SEMPRE popule \"attributes\" com a chave #{slot} (o valor dele, ou a confirmação); " \
      "\"attributes\" NÃO pode vir vazio neste turno. O motor grava o valor proposto se ele confirmar; o novo se ele corrigir."
  end

  # Slot de FORMATO conhecido? Governa o escopo do pré-preenchimento (decisão (D): só formato, onde o gate valida).
  def self.format_slot?(step, slot)
    Ai::SlotExtractor.known_format?(slot_effective_type(step, slot))
  end

  # Tipo efetivo do slot, sem instância (o compiler é class-level, sem conversa): tipo DECLARADO da etapa;
  # 'text' cai na inferência pela chave. Mesma derivação do Ai::SlotCollector#effective_type.
  def self.slot_effective_type(step, slot)
    declared = Ai::StepSlot.type(step)
    declared == 'text' ? (Ai::SlotExtractor.type_for_key(slot) || 'text') : declared
  end

  # (4) FEEDBACK DE REJEIÇÃO POR FORMATO. Quando o último valor do slot CORRENTE foi barrado por formato
  # (ai_last_invalid, gravado por Ai::StateManager#persist_slot_feedback — o motor de validação NÃO é tocado),
  # diz à IA o valor e o tipo esperado para ela EXPLICAR ao cliente em vez de repetir a mesma pergunta — e
  # roteia o "não tenho" para a ausência determinística. É GENÉRICO (qualquer tipo de formato), o texto não
  # cita CPF. Escalada SOFT reusando ai_step_turns (sem contador novo): passado ESCALATE_AFTER, a IA oferece o
  # atendente humano — e é instruída a FAZER o handoff (ação real, gateway.rb:311-331), nunca só prometer.
  ESCALATE_AFTER = 2
  def self.rejection_feedback_line(steps, step_index, slot, slot_feedback)
    invalid = slot_feedback.is_a?(Hash) ? slot_feedback['invalid'] : nil
    return nil unless slot && invalid.is_a?(Hash) && invalid['slot'].to_s == slot.to_s

    list = Array(steps)
    step = list[step_index.to_i.clamp(0, [list.size - 1, 0].max)]
    type = slot_effective_type(step, slot)
    base = "⚠ O último valor informado (\"#{invalid['value']}\") NÃO tem o formato esperado (#{type}). " \
           'Explique isso ao cliente com suas palavras e peça de novo — se ele disser que NÃO TEM esse dado ' \
           '(ex.: estrangeiro sem CPF), registre a ausência; não repita a mesma pergunta.'
    return base if slot_feedback['step_turns'].to_i < ESCALATE_AFTER

    # "falar com um atendente" ESPELHA o gatilho do transfer_when ("cliente pede para falar com atendente"):
    # quanto mais a oferta se parece com o gatilho, maior a chance de a resposta do cliente disparar o handoff.
    "#{base} Como ele já tentou algumas vezes, OFEREÇA falar com um atendente; se ele aceitar, " \
      'FAÇA a transferência (decisão de handoff) — não apenas diga que vai transferir.'
  end

  # Memória PERSISTENTE deste contato, de atendimentos ANTERIORES (Ai::CustomerMemory). Frente C: o bloco só
  # APRESENTA o dado, deixando claro que é de conversas passadas (não desta) — o QUE FAZER com cada dado (usar
  # direto vs propor e confirmar) fica na INSTRUÇÃO da etapa, não aqui. Por isso NÃO diz mais "use e não
  # pergunte de novo": essa diretiva fazia o modelo tratar o dado como já coletado NESTA conversa e pular a
  # confirmação que a instrução pede. Duas partes rotuladas: Resumo (prosa) e Dados (estruturados). [] sem memória.
  def self.customer_memory_lines(customer_memory)
    return [] if customer_memory.nil?

    facts = customer_memory.key_facts.to_h
    return [] if customer_memory.summary.blank? && facts.blank?

    lines = ['Memória deste cliente (de atendimentos ANTERIORES, não desta conversa):']
    lines << "Resumo: #{customer_memory.summary}" if customer_memory.summary.present?
    if facts.present?
      lines << 'Dados deste cliente (de atendimentos anteriores):'
      lines.concat(facts.map { |k, v| "- #{k}: #{v}" })
    end
    [lines.join("\n")]
  end

  # Times de destino do handoff HUMANO oferecidos ao modelo: a whitelist "Transferir para times
  # (humanos)" (agent.handoff_team_ids) — a MESMA lista que Ai::HandoffCoordinator#match_team_by_name
  # aceita. Antes listava TODOS os times da conta: o modelo nomeava um fora da whitelist, o match
  # falhava e caía em fallback silencioso (destino errado, sem sinal). Na ORDEM dos checkboxes (a
  # intenção do usuário), como configured_handoff_team_id. Whitelist VAZIA = configuração ausente:
  # mantém o comportamento antigo (todos os times) mas LOGA um aviso — não deve ser silencioso.
  def self.human_handoff_teams(agent)
    ids = agent.respond_to?(:handoff_team_ids) ? Array(agent.handoff_team_ids) : []
    if ids.empty?
      Rails.logger.warn "[Ai::PromptCompiler] agente #{agent.try(:id)} sem handoff_team_ids: oferecendo " \
                        'TODOS os times da conta ao modelo (fallback). Configure "Transferir para times ' \
                        '(humanos)" para rotear por intenção.'
      return ::Team.where(account_id: agent.account_id).order(:name).to_a
    end

    by_id = ::Team.where(account_id: agent.account_id, id: ids).index_by(&:id)
    ids.filter_map { |id| by_id[id] }
  rescue StandardError => e
    Rails.logger.error "[Ai::PromptCompiler#human_handoff_teams] #{e.class}: #{e.message}"
    ::Team.where(account_id: agent.account_id).order(:name).to_a
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

  # Steps may be the new object form ({name, objective/rules/suggested_script OR legacy instructions})
  # or the legacy string form. Renders one bullet per step: "- Nome: instruções" (Ai::StepInstructionText
  # decide entre o formato estruturado novo e o fallback de texto livre).
  def self.step_lines(steps)
    Array(steps).map do |s|
      if s.is_a?(Hash)
        name = (s['name'] || s[:name]).to_s.strip
        next if name.blank?

        instr = Ai::StepInstructionText.render(s)
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

  # native_tools: true → contrato sem invoke_tool/tool_name/tool_input_json (ferramentas são chamadas
  # nativamente via function_call da API; o modelo NUNCA deve devolver invoke_tool neste modo).
  # native_tools: false (default) → contrato completo com invoke_tool e campos de ferramenta.
  def self.response_contract(native_tools: false)
    if native_tools
      <<~TXT.strip
        Decida a próxima ação. Retorne ESTRITAMENTE um JSON válido, sem texto fora dele:
        {"decision":"reply|handoff|close|noop","reply_text":"texto ao cliente","handoff_reason":"","handoff_target":"","current_step":"","step_completed":false,"asked_slot":"","confidence":0.0,"attributes_list":[]}
        O campo "decision" aceita SOMENTE um destes 4 valores: reply, handoff, close, noop. NÃO invente outros. Para responder ao cliente use SEMPRE "reply". As ferramentas são chamadas diretamente via API — NÃO use decision:"invoke_tool".
        A etapa atual é DEFINIDA PELO SISTEMA (ver "ETAPA ATUAL" acima) — você NÃO escolhe nem muda de etapa. Em "current_step", apenas repita o nome dessa etapa atual como CONFIRMAÇÃO/registro (é só log; não decide o avanço). Em "step_completed", responda true SOMENTE no turno em que CONCLUIR essa etapa (já obteve tudo que ela exigia); nesse momento o SISTEMA avança sozinho para a próxima. Nos demais turnos, responda false. Nunca volte para uma etapa anterior por conta própria.
        Em "attributes_list", liste os dados coletados do cliente como itens {"key":"chave","value":"valor"}; use [] se não houver nada novo.
        Em "asked_slot", informe a CHAVE EXATA do slot que a sua reply_text está pedindo neste turno — incluindo perguntas de ESCOLHA, PERMISSÃO ou CONFIRMAÇÃO cuja resposta preenche o slot. Vazio SÓ quando a resposta do cliente não preenche slot nenhum. Ex.: "Posso te fazer 2 perguntas ou prefere ver os planos?" tem asked_slot = escolha_caminho, porque a resposta do cliente preenche esse slot.
      TXT
    else
      <<~TXT.strip
        Decida a próxima ação. Retorne ESTRITAMENTE um JSON válido, sem texto fora dele:
        {"decision":"reply|invoke_tool|handoff|close|noop","reply_text":"texto ao cliente","tool_name":"","tool_input_json":"{}","handoff_reason":"","handoff_target":"","current_step":"","step_completed":false,"asked_slot":"","confidence":0.0,"attributes_list":[]}
        O campo "decision" aceita SOMENTE um destes 5 valores: reply, invoke_tool, handoff, close, noop. NÃO invente outros (ex.: "text", "message", "resposta"). Para responder ao cliente use SEMPRE "reply".
        A etapa atual é DEFINIDA PELO SISTEMA (ver "ETAPA ATUAL" acima) — você NÃO escolhe nem muda de etapa. Em "current_step", apenas repita o nome dessa etapa atual como CONFIRMAÇÃO/registro (é só log; não decide o avanço). Em "step_completed", responda true SOMENTE no turno em que CONCLUIR essa etapa (já obteve tudo que ela exigia); nesse momento o SISTEMA avança sozinho para a próxima. Nos demais turnos, responda false. Nunca volte para uma etapa anterior por conta própria.
        Para chamar uma ferramenta, preencha "tool_name" com o nome EXATO e "tool_input_json" com o input como STRING JSON (um objeto); sem ferramenta, "tool_name" vazio e "tool_input_json" igual a "{}".
        Em "attributes_list", liste os dados coletados do cliente como itens {"key":"chave","value":"valor"}; use [] se não houver nada novo.
        Em "asked_slot", informe a CHAVE EXATA do slot que a sua reply_text está pedindo neste turno — incluindo perguntas de ESCOLHA, PERMISSÃO ou CONFIRMAÇÃO cuja resposta preenche o slot. Vazio SÓ quando a resposta do cliente não preenche slot nenhum. Ex.: "Posso te fazer 2 perguntas ou prefere ver os planos?" tem asked_slot = escolha_caminho, porque a resposta do cliente preenche esse slot.
      TXT
    end
  end
end
