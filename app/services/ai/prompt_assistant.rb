# Dev-time helper that suggests good prompts. Given a free-text brief from the user, generates ONE
# text suggestion for either an agent base_prompt or a playbook step's instructions. Suggestion-only
# (the UI never auto-fills — the user copies if they like it). NOT tied to a conversation/agent: it's
# account-scoped. Reuses Ai::ModelRouter (cheap fixed model) and records an Ai::Run for audit/cost —
# consuming the account's AI credits like every other AI call.
class Ai::PromptAssistant
  MODEL = 'gpt-4.1-mini'
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

    3. Regra anti-repetição — inclua LITERALMENTE no base_prompt uma instrução equivalente a esta:
       "Quando o cliente responder 'sim', 'isso', 'isso mesmo', 'confirmado' ou 'pode ser', isso
       CONFIRMA a última pergunta que você fez: trate como resolvido e AVANCE para o próximo passo.
       NUNCA repita a mesma pergunta nem peça a mesma confirmação de novo."

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

    4. Atributos estruturados. Quando a etapa envolver uma DECISÃO/classificação do cliente
       (confirmação de interesse, tipo residencial/empresa, plano escolhido), sugira EXPLICITAMENTE
       qual atributo personalizado (custom attribute) gravar para marcar isso — ex.: "grave
       tipo_cliente = residencial|empresa", "marque interesse_confirmado = true". Assim a decisão
       fica PERSISTIDA e a IA não depende só do texto livre da conversa (que é o que causa loop).

    5. Seja concreto e conciso: instruções acionáveis, não teoria.

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
    result = Ai::ModelRouter.decide(
      profile: nil, provider: 'openai', model: MODEL,
      system_prompt: system_prompt(@kind), user_message: @brief, account_id: @account.id, json: true
    )
    record_run(run, result)

    { 'suggestion' => extract_suggestion(result), 'run_id' => run.id, 'status' => result[:status] }
  rescue StandardError => e
    Rails.logger.error "[Ai::PromptAssistant] account=#{@account&.id} kind=#{@kind} #{e.class}: #{e.message}"
    { 'error' => "#{e.class}: #{e.message}" }
  end

  private

  # The model returns { "suggestion": "<texto>" } (json: true). Degrade gracefully to raw text.
  def extract_suggestion(result)
    decision = result[:decision]
    return decision['suggestion'].to_s if decision.is_a?(Hash) && decision['suggestion'].present?

    decision.is_a?(Hash) ? decision.to_json : decision.to_s
  end

  def record_run(run, result)
    run.update!(
      provider: result[:provider], model: result[:model], tokens_in: result[:tokens_in],
      tokens_out: result[:tokens_out], cost: result[:cost], latency_ms: result[:latency_ms],
      decision: result[:decision] || {}, status: result[:status]
    )
  end

  def system_prompt(kind)
    kind == 'base_prompt' ? BASE_PROMPT_SYSTEM : STEP_INSTRUCTIONS_SYSTEM
  end
end
