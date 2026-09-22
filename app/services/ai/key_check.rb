# Diagnóstico da chave de IA EFETIVA de uma conta: QUAL chave os módulos de IA vão realmente usar
# para este account_id, e se ela funciona de verdade.
#
# Existe porque o "Testar conexão" anterior dava 200 sem provar nada do uso real:
#   1. lia a config pela cascata conta→global→ENV (IntegrationSettingsService.get_config), então
#      podia estar validando a chave do SERVIDOR e reportando sucesso para uma conta que nunca
#      cadastrou chave nenhuma — exatamente o cenário que fazia o orquestrador Python rodar na
#      chave do backend sem ninguém perceber;
#   2. chamava GET /v1/models, que uma chave SEM CRÉDITO responde 200 normalmente. O runtime usa
#      POST /v1/responses com um modelo específico — é lá que 429 insufficient_quota e
#      model_not_found aparecem, e o teste nunca chegava nesse caminho.
#
# Aqui a chave é resolvida pela MESMA função que o runtime usa (Ai::ModelRouter.account_provider_key,
# só a linha da própria conta + feature) e a sonda é uma chamada REAL no mesmo endpoint e com o
# mesmo modelo que a conta usa em produção.
class Ai::KeyCheck
  PROVIDER = 'openai'.freeze
  RESPONSES_URL = 'https://api.openai.com/v1/responses'.freeze
  TIMEOUT = 20
  # Sonda mínima: o objetivo é exercitar auth + cota + modelo, não gerar texto.
  PROBE_INPUT = 'ping'.freeze
  PROBE_MAX_OUTPUT_TOKENS = 16

  def initialize(account:)
    @account = account
  end

  # Nunca devolve só um booleano: o motivo faz parte do contrato. "não configurada", "chave
  # inválida", "sem crédito no provedor" e "rodando na chave da plataforma" exigem ações
  # completamente diferentes de quem está na tela, e antes todas chegavam no front como o mesmo
  # sucesso/silêncio.
  def perform
    return no_key_result if api_key.blank?

    probe
  end

  # Estado SEM chamar a rede — para o front pintar o badge ao abrir a tela.
  def status
    {
      account_id: @account.id,
      provider: PROVIDER,
      key_source: key_source,
      key_reason: key_reason,
      # Só da chave DA CONTA. A tela é do admin do cliente, não da SCNET: um preview da chave da
      # plataforma entregaria pedaços de um segredo do servidor a todo tenant que abrisse a aba.
      key_preview: account_key.present? ? mask(account_key) : nil,
      # Sem isto a tela dizia "usando a chave da plataforma" mesmo quando o servidor NÃO tem chave
      # nenhuma — contradizendo o próprio resultado do teste ("o servidor também não tem chave
      # configurada") e escondendo que, nesse estado, a IA simplesmente não responde.
      platform_key_present: platform_key.present?,
      model: model,
      credits: credits_info
    }
  end

  private

  # A chave que o runtime usaria para ESTA conta, na ordem real: chave própria da conta (feature
  # custom_llm_api_key + linha da própria conta no Hub) e, na falta dela, a chave da plataforma.
  def api_key
    return @api_key if defined?(@api_key)

    @api_key = account_key || platform_key
  end

  def account_key
    return @account_key if defined?(@account_key)

    @account_key = Ai::ModelRouter.account_provider_key(@account.id, PROVIDER)
  end

  def platform_key
    Ai::ModelRouter.credential('CAPTAIN_OPEN_AI_API_KEY', 'OPENAI_API_KEY')
  end

  def key_source
    account_key.present? ? 'account' : 'platform'
  end

  # POR QUE a conta não está na própria chave. Cada motivo tem uma correção diferente na tela, e é
  # o que o front precisa para não mostrar "não configurado" quando o caso é outro.
  def key_reason
    return 'account_key' if account_key.present?
    return 'feature_disabled' unless @account.feature_enabled?('custom_llm_api_key')

    setting = IntegrationSetting.find_by(account_id: @account.id, provider: PROVIDER)
    return 'not_configured' if setting.nil?
    return 'provider_disabled' unless setting.enabled?

    'key_missing'
  end

  # Mesmo modelo que a conta roda de verdade: o do Hub, senão o do perfil de operação que o
  # orquestrador recebe (Ai::PythonOrchestratorClient#payload[:model]), senão o default do provider.
  def model
    @model ||= IntegrationSettingsService.account_only_config(@account.id, PROVIDER)['model'].presence ||
               profile_model ||
               Ai::ModelRouter::DEFAULT_MODELS[PROVIDER]
  end

  def profile_model
    Ai::OperationProfile.where(account_id: @account.id, supervisor_provider: PROVIDER)
                        .order(:id).first&.supervisor_model.presence
  end

  # Saldo da plataforma só importa quando é a plataforma que paga a conversa. Na chave própria o
  # consumo não debita crédito (Ai::ActionDispatcher#consume_credit).
  def credits_info
    return nil if key_source == 'account'

    balance = @account.ai_credit_balance
    return { total: nil, enforced: false } if balance.nil?

    { total: balance.total, enforced: true }
  end

  def probe
    started = Time.current
    response = HTTParty.post(
      RESPONSES_URL,
      headers: { 'Authorization' => "Bearer #{api_key}", 'Content-Type' => 'application/json' },
      body: { model: model, input: PROBE_INPUT, max_output_tokens: PROBE_MAX_OUTPUT_TOKENS }.to_json,
      timeout: TIMEOUT
    )
    latency = ((Time.current - started) * 1000).round
    response.success? ? success_result(latency) : failure_result(response, latency)
  rescue StandardError => e
    Rails.logger.warn "[Ai::KeyCheck] account_id=#{@account.id} sonda falhou: #{e.class}: #{e.message}"
    result(ok: false, level: 'error', code: 'network_error',
           message: "Não foi possível falar com a OpenAI: #{e.message}")
  end

  def success_result(latency)
    if key_source == 'account'
      result(ok: true, level: 'success', code: 'account_key_valid', latency_ms: latency,
             message: "Chave própria da conta ##{@account.id} validada em uma chamada real " \
                       "(#{model}, #{latency}ms). Os módulos de IA desta conta usam esta chave.")
    else
      result(ok: true, level: 'warning', code: 'platform_key_valid', latency_ms: latency,
             message: "A chamada funcionou (#{model}, #{latency}ms), mas na chave da PLATAFORMA: " \
                       "#{reason_text}. O consumo desta conta sai dos créditos do plano#{credits_text}.")
    end
  end

  # A mensagem crua do provider é o que diz se é chave revogada, cota estourada ou modelo inexistente
  # — antes tudo isso virava a mesma "Falha na conexão. Verifique as credenciais." no front.
  def failure_result(response, latency)
    body = response.parsed_response.is_a?(Hash) ? response.parsed_response : {}
    detail = body.dig('error', 'message').presence || "HTTP #{response.code}"
    code = failure_code(response.code, body.dig('error', 'code').to_s)
    result(ok: false, level: 'error', code: code, latency_ms: latency,
           message: "#{failure_prefix(code)} #{detail}")
  end

  def failure_code(http_code, provider_code)
    return 'insufficient_quota' if provider_code == 'insufficient_quota'
    return 'model_not_found' if provider_code == 'model_not_found'

    case http_code
    when 401 then 'invalid_key'
    when 403 then 'forbidden'
    when 429 then 'rate_limited'
    when 404 then 'model_not_found'
    else 'provider_error'
    end
  end

  def failure_prefix(code)
    case code
    when 'invalid_key' then "Chave #{key_source == 'account' ? 'da conta' : 'da plataforma'} inválida ou revogada:"
    when 'insufficient_quota' then 'Chave válida, mas a conta na OpenAI está sem crédito/cota:'
    when 'model_not_found' then "O modelo \"#{model}\" não existe ou não está liberado para esta chave:"
    when 'rate_limited' then 'Chave válida, mas o provedor limitou a taxa de requisições:'
    when 'forbidden' then 'Chave sem permissão para este recurso:'
    else 'O provedor recusou a chamada:'
    end
  end

  def no_key_result
    result(ok: false, level: 'error', code: 'no_key_available',
           message: "Nenhuma chave disponível para a conta ##{@account.id}: #{reason_text} " \
                     'e o servidor também não tem chave configurada.')
  end

  def reason_text
    case key_reason
    when 'feature_disabled' then 'esta conta não tem a Chave Própria de IA liberada no plano'
    when 'not_configured' then 'esta conta não cadastrou chave própria'
    when 'provider_disabled' then 'a integração OpenAI está desativada nesta conta'
    when 'key_missing' then 'a configuração desta conta não tem uma API Key salva'
    else 'chave própria em uso'
    end
  end

  def credits_text
    credits = credits_info
    return '' if credits.nil? || credits[:total].nil?

    " (saldo atual: #{credits[:total]})"
  end

  def result(attrs)
    status.merge(key_reason_text: reason_text).merge(attrs)
  end

  def mask(key)
    return nil if key.blank?

    "#{key.to_s.first(4)}#{'*' * 12}#{key.to_s.last(3)}"
  end
end
