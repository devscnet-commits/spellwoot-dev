# Worker de JULGAMENTO DE CAPTURA (opt-in, DESLIGADO por padrão). Decide se a mensagem do turno
# RESPONDE ao dado que a etapa corrente coleta — cobrindo slots SEM formato validável, onde a regra
# determinística do #269 (type_for_key + attempt?) não alcança (ex.: "para o dia 10" tem dígito e
# passaria como tentativa de telefone). NÃO conversa com o cliente, NÃO injeta RAG/catálogo, NÃO manda
# o histórico — só a instrução da etapa, a chave do slot, o texto do turno e os fatos já coletados.
#
# Custo: cria Ai::Run (run_type 'capture_judge') e grava provider/model/tokens/cost/latency — padrão do
# OCR (Ai::Workers::MediaProcessor#vision_call), NÃO o do Summary (que não debita).
#
# Saída (JSON estrito, 3 estados): {status:'answered',value:} | {status:'malformed',value:} |
# {status:'not_an_answer'}. Falha (erro/timeout/JSON inválido/status desconhecido/value vazio) =>
# {status:'failed', reason:} — o caller NÃO grava e NÃO avança (gravar errado é pior que reperguntar).
class Ai::Workers::CaptureJudge
  REQUEST_TIMEOUT = 20

  # Valores aceitos de asks_about (kind de conhecimento) + 'nada'. Qualquer outro vira 'nada' no parse.
  VALID_ASKS = %w[produto faq procedimento documento nada].freeze

  SYSTEM_PROMPT = <<~PROMPT.freeze
    Você é um JUIZ DE CAPTURA em um atendimento automatizado. Sua ÚNICA função é decidir se a MENSAGEM
    DO CLIENTE responde ao DADO que a etapa atual está coletando. Você NÃO fala com o cliente, NÃO
    responde perguntas, NÃO usa catálogo/base de conhecimento e NÃO inventa dados.

    Responda ESTRITAMENTE um JSON válido, sem nenhum texto fora dele, em UM destes três formatos:
    - A mensagem CONTÉM o dado pedido (formato plausível para a chave):
      {"status":"answered","value":"<somente o dado, limpo, sem o texto ao redor>"}
    - A mensagem TENTA responder o dado pedido, mas veio incompleta/estranha para o que foi pedido:
      {"status":"malformed","value":"<o que o cliente enviou, exatamente como veio>"}
    - A mensagem NÃO é uma resposta ao dado pedido:
      {"status":"not_an_answer"}

    Regras (determinam o que entra na memória do cliente — seja rigoroso):
    1. Uma confirmação isolada ("sim", "ok", "pode ser", "isso", "está correto", "correto") NUNCA é o
       dado — é "not_an_answer", A MENOS que a INSTRUÇÃO peça explicitamente um sim/não.
    2. Uma pergunta do cliente ("qual plano?", "quanto custa?") é sempre "not_an_answer".
    3. Saudação, agradecimento ou assunto diferente do dado pedido é "not_an_answer".
    4. Em "answered", extraia SOMENTE o dado. Ex.: de "meu telefone é 4998564780" devolva "4998564780".
       Se o conteúdo não corresponde ao TIPO do dado pedido (ex.: a chave é um telefone e o cliente
       fala de uma data, "para o dia 10"), isso NÃO é o dado -> "not_an_answer".
    5. Use os DADOS JÁ COLETADOS apenas para entender o contexto e NÃO confundir o dado desta etapa com
       o de outra etapa. Nunca copie um valor já coletado como resposta.
    6. Na dúvida entre "answered" e "not_an_answer", escolha "not_an_answer". Gravar um dado errado é
       pior do que pedir de novo.

    ALÉM do status acima, inclua em TODA resposta DOIS campos sobre a INTENÇÃO do cliente NESTE turno —
    eles são INDEPENDENTES do status (um turno "not_an_answer" para o dado pode ter asks_about="produto"):
    - "asks_about": se o cliente está PERGUNTANDO algo que exige a base de conhecimento, o TIPO do que
      ele quer — "produto" (planos, preços, catálogo, o que a empresa vende), "faq" (dúvida geral),
      "procedimento" (como fazer/resolver algo) ou "documento". Se o turno NÃO é uma pergunta desse tipo
      (é resposta a um dado, saudação, confirmação, etc.), use "nada".
    - "query": em POUCAS palavras, o que o cliente quer saber (ex.: "planos e preços"); string vazia
      quando asks_about é "nada".
    Exemplo: cliente pergunta "quais os valores?" numa etapa que coleta o nome ->
      {"status":"not_an_answer","asks_about":"produto","query":"valores dos planos"}
  PROMPT

  # Julga o turno. profile define provider/model (worker_overrides['capture_judge']) com fallback pro
  # supervisor. conversation dá account_id/conversation_id p/ o Ai::Run e os fatos já coletados. Retorna
  # sempre um Hash com :status (answered|malformed|not_an_answer|failed).
  def self.judge(step:, slot:, message_text:, profile:, conversation:)
    return { status: 'failed', reason: 'blank_message' } if message_text.to_s.strip.empty?

    provider, model = worker_config(profile)
    user_msg = user_message(step, slot, message_text, collected_facts(conversation))
    raw = call_with_run(provider, model, user_msg, conversation)
    return { status: 'failed', reason: raw[:error].to_s.first(200) } if raw[:status] == 'error'

    parse(raw[:text])
  rescue StandardError => e
    Rails.logger.error "[Ai::Workers::CaptureJudge] #{e.class}: #{e.message}"
    { status: 'failed', reason: e.class.to_s }
  end

  # Chamada COM DÉBITO: cria Ai::Run (run_type 'capture_judge') e grava tokens/cost/latency — padrão do
  # OCR (media_processor.rb:169-181). Devolve o mesmo hash do call_model.
  def self.call_with_run(provider, model, user_msg, conversation)
    run = Ai::Run.create!(account_id: conversation.account_id, conversation_id: conversation.id,
                          run_type: 'capture_judge', mode: 'worker', worker: 'capture_judge', status: 'running')
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    raw = Ai::ModelRouter.call_model(
      provider: provider, model: model, system_prompt: SYSTEM_PROMPT, user_message: user_msg,
      account_id: conversation.account_id, json: true, timeout: REQUEST_TIMEOUT
    )
    latency_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
    tin = raw[:tokens_in].to_i
    tout = raw[:tokens_out].to_i
    run.update!(provider: provider, model: model, tokens_in: tin, tokens_out: tout,
                cost: Ai::ModelRouter.estimate_cost(model, tin, tout), latency_ms: latency_ms,
                status: raw[:status] == 'error' ? 'error' : 'recorded')
    raw
  end

  def self.collected_facts(conversation)
    (conversation.additional_attributes || {})['ai_collected_facts']
  end

  # provider/model do perfil (worker_overrides['capture_judge']) com fallback pro supervisor — mesmo
  # padrão do Summary (summary.rb:39-47).
  def self.worker_config(profile)
    cfg = profile&.worker(:capture_judge) || {}
    [cfg['provider'].presence || profile&.supervisor_provider.presence || 'openai',
     cfg['model'].presence || profile&.supervisor_model.presence || 'gpt-4.1-mini']
  end

  def self.user_message(step, slot, message_text, collected)
    instruction = Ai::StepInstructionText.render(step).to_s
    facts = (collected || {}).reject { |_k, v| v.to_s.strip.empty? }
                             .map { |k, v| "#{k}=#{v}" }.join(', ').presence || 'nenhum'
    <<~MSG.strip
      INSTRUÇÃO DA ETAPA: #{instruction}
      DADO A COLETAR (chave): #{slot}
      DADOS JÁ COLETADOS: #{facts}
      MENSAGEM DO CLIENTE: #{message_text.to_s.strip}
    MSG
  end

  # Parse tolerante: pega o objeto JSON e valida os 3 status. value obrigatório p/ answered/malformed.
  # asks_about/query (intenção, camada 2) entram em TODO retorno de parse — validados por #intent.
  def self.parse(text)
    json = text.to_s[/\{.*\}/m]
    return { status: 'failed', reason: 'no_json' } if json.blank?

    data = JSON.parse(json)
    intent = intent_fields(data)
    status = data['status'].to_s
    case status
    when 'answered', 'malformed'
      value = data['value'].to_s.strip
      value.present? ? { status: status, value: value, **intent } : { status: 'failed', reason: 'blank_value', **intent }
    when 'not_an_answer'
      { status: 'not_an_answer', **intent }
    else
      { status: 'failed', reason: "unknown_status:#{status.first(40)}", **intent }
    end
  rescue JSON::ParserError
    { status: 'failed', reason: 'invalid_json' }
  end

  # Intenção do turno (camada 2): asks_about validado contra VALID_ASKS (desconhecido -> 'nada'); query
  # limitada. Sempre devolve os dois — o caller decide se e como usa (a captura ignora estes campos).
  def self.intent_fields(data)
    ask = data['asks_about'].to_s.strip.downcase
    ask = 'nada' unless VALID_ASKS.include?(ask)
    { asks_about: ask, query: data['query'].to_s.strip.first(200) }
  end
end
