# Dev-time helper that suggests good prompts. Given a free-text brief from the user, generates ONE
# text suggestion for either an agent base_prompt or a playbook step's instructions. Suggestion-only
# (the UI never auto-fills — the user copies if they like it). NOT tied to a conversation/agent: it's
# account-scoped. Reuses Ai::ModelRouter (cheap fixed model) and records an Ai::Run for audit/cost —
# consuming the account's AI credits like every other AI call.
class Ai::PromptAssistant
  MODEL = 'gpt-4.1-mini'.freeze
  KINDS = %w[base_prompt step_instructions].freeze

  # System prompt para gerar o base_prompt de um agente. As regras obrigatórias derivam do bug real
  # de loop de repergunta (config ruim: placeholders vazios, perguntas compostas, sem regra
  # anti-repetição) — o gerador é instruído a NUNCA produzir esses padrões.
  BASE_PROMPT_SYSTEM = <<~PROMPT.freeze
    Você é um ESPECIALISTA em escrever prompts (o campo "base_prompt") para agentes de IA de
    atendimento ao cliente por chat (WhatsApp). A partir do pedido do usuário — que descreve o
    negócio e o objetivo do agente — gere UM base_prompt completo, pronto para colar, em português
    do Brasil, no tom que o usuário pediu.

    REGRAS OBRIGATÓRIAS. O texto que você gerar DEVE segui-las à risca:

    1. PROIBIDO placeholder vazio. Nunca escreva "[liste as cidades]", "[preencha a tabela]",
       "[insira aqui]" ou colchetes esperando preenchimento silencioso — isso faz a IA final
       ALUCINAR (afirmar dados que não tem). Se faltar um dado específico do negócio (preços,
       planos, cidades de cobertura, horários) no pedido do usuário: NÃO invente como se fosse
       verdade — escreva um bloco de exemplo aberto com o aviso, em maiúsculas, "EXEMPLO —
       SUBSTITUA POR DADOS REAIS ANTES DE PUBLICAR:" seguido de um exemplo plausível.

    2. UMA pergunta por vez. Instrua a IA a pedir UMA única informação por mensagem. É PROIBIDO
       gerar instruções que levem a perguntas compostas do tipo "É residencial ou empresarial? E
       qual a cidade?". Uma coisa de cada vez.

    3. Regra anti-repetição — sugira incluir no base_prompt uma instrução equivalente a esta,
       adaptando ao tom do agente (não precisa copiar a frase exata): quando o cliente responder
       "sim", "isso", "isso mesmo", "confirmado" ou "pode ser", isso CONFIRMA a última pergunta
       feita — trate como resolvido e AVANCE para o próximo passo, sem repetir a mesma pergunta
       nem pedir a mesma confirmação de novo.

    4. Inclua também: cumprimentar só na PRIMEIRA mensagem (não repetir saudações depois) e NÃO
       reperguntar o que já constar no bloco "Dados já coletados".

    5. Estrutura clara, em seções curtas e objetivas, SEM duplicar instruções (não repita a mesma
       regra em dois lugares do prompt).

    Retorne ESTRITAMENTE um JSON válido, sem nenhum texto fora dele:
    {"suggestion":"<o base_prompt completo, com quebras de linha reais>"}
  PROMPT

  # System prompt para gerar instruções de etapa (step) do playbook. Regras derivadas do mesmo bug:
  # etapas com nomes genéricos e sem critério de transição fazem a IA orbitar e reperguntar.
  STEP_INSTRUCTIONS_SYSTEM = <<~PROMPT.freeze
    Você é um ESPECIALISTA em desenhar o playbook (as etapas) de agentes de IA de atendimento. A
    partir do pedido do usuário, gere as INSTRUÇÕES de UMA etapa — ou de uma sequência curta de
    etapas, se o pedido pedir — em português do Brasil, prontas para colar no campo de instruções.

    REGRAS OBRIGATÓRIAS:

    1. Nome de etapa FIXO e ESPECÍFICO. Nunca um nome genérico solto como "Qualificação" ou
       "Atendimento". Use nomes que digam exatamente o que a etapa faz e quais dados envolve — por
       exemplo "Qualificação: cidade e tipo de cliente", "Verificação de cobertura", "Apresentação
       de planos". Nomes específicos permitem que a IA se ANCORE na etapa de forma estável entre
       turnos, em vez de reinventar o nome a cada mensagem e ficar em loop.

    2. Critério de transição EXPLÍCITO. Toda etapa deve terminar dizendo, de forma objetiva, QUANDO
       avançar: "Avance para a próxima etapa assim que tiver capturado X e Y." Sem esse gatilho, a
       IA não percebe que já concluiu a etapa e repergunta.

    3. Uma etapa NÃO pede duas informações não relacionadas na mesma pergunta. Se a etapa precisa de
       duas coisas, instrua a coletá-las UMA por vez, em mensagens separadas.

    4. Atributos estruturados. Quando a etapa envolver uma DECISÃO/classificação ou um DADO do cliente
       (confirmação de interesse, tipo residencial/empresa, plano escolhido, cidade, tamanho do imóvel),
       instrua EXPLICITAMENTE a IA a persistir o valor SEMPRE com a frase "salve no atributo
       <nome_da_chave>" usando snake_case na chave — ex.: "salve no atributo tipo_cliente =
       residencial|empresa", "salve no atributo interesse_confirmado = true", "salve no atributo
       tamanho_imovel". O snake_case é o que o sistema usa para saber qual chave persistir. Assim a
       decisão fica PERSISTIDA e a IA não depende só do texto livre da conversa (o que causa loop).
       OBSERVAÇÃO: se o usuário quiser esse dado ESTRUTURADO (visível no painel, exportável para
       CRM/Bitrix), ele precisa criar o atributo personalizado com a MESMA chave (snake_case idêntico);
       se não criar, o dado ainda é LEMBRADO pela IA (memória de fatos), mas não vira campo estruturado.

    5. Seja concreto e conciso: instruções acionáveis, não teoria.

    6. TODA etapa gerada deve incluir uma cláusula de escape genérica ao final, adaptada ao contexto
       da etapa: "Se o cliente não fornecer o dado após tentativas razoáveis (ou responder de forma
       ambígua repetidamente), NÃO fique repetindo a mesma pergunta. Registre o melhor valor
       disponível (estimativa razoável, se aplicável) e avance — ou, se não for possível prosseguir
       sem esse dado, transfira para atendimento humano." Essa cláusula é OBRIGATÓRIA mesmo que o
       usuário não a peça explicitamente no pedido — é responsabilidade sua incluir, não do usuário
       lembrar.

    7. NUNCA mencione botões, opções clicáveis ou UI interativa (ex.: "com botões X e Y"). O canal do
       cliente é texto livre — ele sempre digita a resposta, nunca clica. Ao invés disso, oriente a
       IA a aceitar qualquer forma de expressar a mesma escolha (respostas curtas como "sim", "pode",
       sinônimos) e a gravar o atributo IMEDIATAMENTE na primeira resposta suficientemente clara, sem
       exigir uma segunda pergunta de confirmação antes de gravar.

    Retorne ESTRITAMENTE um JSON válido, sem nenhum texto fora dele:
    {"suggestion":"<as instruções da(s) etapa(s), com quebras de linha reais>"}
  PROMPT

  def initialize(account:, kind:, brief:, requested_by: nil)
    @account = account
    @kind = kind.to_s
    @brief = brief.to_s
    @requested_by = requested_by
  end

  def suggest
    return { 'error' => 'kind inválido' } unless KINDS.include?(@kind)
    return { 'error' => 'descreva o que você quer no campo de texto' } if @brief.strip.blank?

    run = Ai::Run.create!(account_id: @account.id, run_type: 'prompt_assistant', mode: 'assistant', status: 'running')
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    # call_model (entrada LIVRE, SEM schema) — como o handoff_summary/CaptureJudge. O `decide` imporia o
    # DecisionSchema strict e a saída viraria o ENVELOPE de decisão (decision/asked_slot/proposed_value/...),
    # NUNCA o {"suggestion"} que o prompt pede (bug #302: o formato dependia de qual método chamava o modelo).
    raw = Ai::ModelRouter.call_model(
      provider: 'openai', model: MODEL,
      system_prompt: system_prompt(@kind), user_message: @brief, account_id: @account.id, json: true
    )
    suggestion = extract_suggestion(raw[:text])
    record_run(run, raw, suggestion, started)

    { 'suggestion' => suggestion, 'run_id' => run.id, 'status' => raw[:status] == 'error' ? 'error' : 'recorded' }
  rescue StandardError => e
    Rails.logger.error "[Ai::PromptAssistant] account=#{@account&.id} kind=#{@kind} #{e.class}: #{e.message}"
    { 'error' => "#{e.class}: #{e.message}" }
  end

  private

  # call_model devolve TEXTO CRU (sem schema): extraímos o {"suggestion":...} nós mesmos (parser tolerante,
  # como o handoff_summary#extract_summary). Degrada para o texto cru quando não vier JSON.
  def extract_suggestion(text)
    str = text.to_s
    if (json = str[/\{.*\}/m])
      value = begin
        JSON.parse(json)['suggestion']
      rescue JSON::ParserError
        nil
      end
      return value.to_s if value.present?
    end
    str.strip
  end

  # call_model NÃO devolve cost/latency (o decide devolvia) — computamos aqui, como o handoff_summary, senão
  # o ai:cost_report subconta o assistente.
  def record_run(run, raw, suggestion, started)
    tin = raw[:tokens_in].to_i
    tout = raw[:tokens_out].to_i
    run.update!(
      provider: raw[:provider] || 'openai', model: raw[:model] || MODEL, tokens_in: tin, tokens_out: tout,
      cost: Ai::ModelRouter.estimate_cost(MODEL, tin, tout),
      latency_ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round,
      decision: { 'suggestion' => suggestion }, status: raw[:status] == 'error' ? 'error' : 'recorded'
    )
  end

  def system_prompt(kind)
    kind == 'base_prompt' ? BASE_PROMPT_SYSTEM : STEP_INSTRUCTIONS_SYSTEM
  end
end
