# Provider-agnostic model call driven by the operation profile (supervisor_provider/model).
# Reuses RubyLLM technically; configures the right provider key (the Chatwoot Llm::Config wires
# only OpenAI, so we wire the others here from InstallationConfig or ENV). Defensive: any failure
# returns an 'error' result + reason so the pipeline records the run instead of crashing.
class Ai::ModelRouter
  # Prices live in config/llm_prices.yml (versioned) and can be overridden without deploy via an
  # InstallationConfig named AI_LLM_PRICES. See price_table / price_for below.
  PRICES_CACHE_KEY = 'ai_llm_prices_table'.freeze
  PRICES_CACHE_TTL = 1.hour
  PRICES_CONFIG = 'AI_LLM_PRICES'.freeze
  # Last-resort default if the yml is missing/unreadable AND no override exists — only a crash guard
  # so estimate_cost never divides against a nil price; the real default comes from the yml.
  SAFETY_DEFAULT_PRICE = [0.001, 0.003].freeze

  # provider/model override the profile's supervisor (used by the confidence router to call the
  # cheap or premium tier). Falls back to the profile's supervisor when not given.
  # Sensible default model per provider, used only when neither the call nor the profile names one.
  DEFAULT_MODELS = {
    'openai' => 'gpt-4.1-mini',
    'anthropic' => 'claude-3-5-sonnet-latest',
    'google' => 'gemini-1.5-flash',
    'gemini' => 'gemini-1.5-flash',
    'openrouter' => 'openai/gpt-4.1-mini',
    # Groq: rede de segurança para o campo de modelo vazio. Só o gpt-oss-120b foi aprovado no smoke
    # test (os llama saíram do personagem / alucinaram). Ver Ai::OperationProfile::GROQ_APPROVED_MODELS.
    'groq' => 'openai/gpt-oss-120b'
  }.freeze
  # Fallback quando não há profile (a coluna supervisor_temperature já nasce 0.3). Baixa = respostas
  # mais consistentes/determinísticas, adequado a atendimento.
  DEFAULT_TEMPERATURE = 0.3

  # json: opt-in to force a JSON-object response (OpenAI response_format). Only the supervisor
  # decision path sets it — its prompt always carries the JSON contract. Plain-text callers (e.g.
  # the department classifier) must leave it false so they aren't forced into JSON mode.
  # force_global_key: BYOK (billing Fase 3). Quando true, ignora a chave própria da conta e usa a chave
  # global da SCNET — o Gateway aciona isso no retry após a chave do cliente falhar por auth (401).
  # schema: :auto (default) resolve o DecisionSchema padrão; passe uma classe de schema para forçar
  # (ex.: Ai::DecisionSchema.without_reply_text na Fase A do split) ou nil para desligar. tools: array de
  # RubyLLM::Tool (só no split ON, Fase A single-call) — anexadas via with_tools quando presentes.
  def self.decide(profile:, system_prompt:, user_message:, provider: nil, model: nil, account_id: nil,
                  temperature: nil, json: false, force_global_key: false, schema: :auto, tools: nil)
    # Default to openai: it reuses the platform's always-configured Captain key, so an agent with no
    # level (or a level missing a provider) still answers instead of crashing for an Anthropic key.
    provider = provider.presence || profile&.supervisor_provider.presence || 'openai'
    model    = model.presence || profile&.supervisor_model.presence || DEFAULT_MODELS.fetch(provider, 'gpt-4.1-mini')
    temperature = resolve_temperature(temperature, profile, provider)

    # Structured Output (strict) na decisão do supervisor quando ligado + provider suportado; senão nil
    # (cai no response_format json_object de hoje). Só o caminho de DECISÃO passa schema — CaptureJudge/
    # visão continuam com json_object/plain. schema != :auto = override explícito (split Fase A).
    schema = decision_schema_for(provider, json) if schema == :auto

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    raw = call_model(provider: provider, model: model, system_prompt: system_prompt,
                     user_message: user_message, account_id: account_id, temperature: temperature, json: json,
                     force_global_key: force_global_key, schema: schema, tools: tools)
    latency_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round

    # Ponto ÚNICO de parse + normalização: com schema o ruby_llm já devolve Hash; sem schema, parse
    # tolerante da String (rede de segurança #unparsed intacta). normalize_decision remonta o formato
    # interno (attributes Hash, tool{name,input}) que Gateway/StateManager/TurnCapture esperam.
    decision = raw[:status] == 'error' ? { 'error' => raw[:error] } : normalize_decision(coerce_decision(raw[:text]))

    {
      provider: provider,
      model: model,
      temperature: temperature.to_f,
      decision: decision,
      tokens_in: raw[:tokens_in],
      tokens_out: raw[:tokens_out],
      cached_tokens: raw[:cached_tokens],
      cost: estimate_cost(model, raw[:tokens_in], raw[:tokens_out]),
      latency_ms: latency_ms,
      status: raw[:status],
      # BYOK: 'auth_error' (401) vs 'provider_error' (demais) — o Gateway usa isso para o fallback.
      error_type: raw[:error_type]
    }
  end

  # NOTE: validate the exact RubyLLM call shape when running; isolated here on purpose.
  # image: anexo para modelos de VISÃO (aceita ActiveStorage::Attached/Blob, path ou URL — o ruby_llm
  # resolve o tipo). nil = chamada de texto normal (comportamento inalterado: `with: nil` == sem anexo).
  # Temperatura: override cru explícito (ex.: Fase A do split = 0.2) vence e passa direto; senão traduz a
  # POSIÇÃO abstrata do perfil (0-100) via TemperatureMapper (o slider). Sem perfil, default. `.nil?`
  # (não ||) preserva um override 0.0.
  def self.resolve_temperature(temperature, profile, provider)
    return temperature unless temperature.nil?
    return Ai::TemperatureMapper.resolve(provider, profile.temperature_position) if profile

    DEFAULT_TEMPERATURE
  end

  # Geração de TEXTO puro (Fase B do split: resposta ao cliente com a voz do perfil). Sem schema/json —
  # saída é string. Reusa call_model (json:false => nem json_object nem schema). Devolve texto + custo.
  def self.generate_text(profile:, system_prompt:, user_message:, provider: nil, model: nil, account_id: nil,
                         temperature: nil, force_global_key: false, tools: nil)
    provider = provider.presence || profile&.supervisor_provider.presence || 'openai'
    model    = model.presence || profile&.supervisor_model.presence || DEFAULT_MODELS.fetch(provider, 'gpt-4.1-mini')
    temperature = resolve_temperature(temperature, profile, provider)

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    raw = call_model(provider: provider, model: model, system_prompt: system_prompt, user_message: user_message,
                     account_id: account_id, temperature: temperature, json: false, force_global_key: force_global_key,
                     tools: tools)
    latency_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round

    { provider: provider, model: model, temperature: temperature.to_f,
      text: raw[:text].to_s, tokens_in: raw[:tokens_in], tokens_out: raw[:tokens_out],
      cached_tokens: raw[:cached_tokens], cost: estimate_cost(model, raw[:tokens_in], raw[:tokens_out]),
      latency_ms: latency_ms, status: raw[:status], error_type: raw[:error_type] }
  end

  def self.call_model(provider:, model:, system_prompt:, user_message:, account_id: nil, temperature: nil,
                      timeout: nil, json: false, image: nil, force_global_key: false, schema: nil, tools: nil)
    raise 'RubyLLM indisponível' unless defined?(RubyLLM)

    context = provider_context(provider, account_id: account_id, timeout: timeout, force_global_key: force_global_key)
    # Groq: endpoint OpenAI-compatible (openai_api_base no context) + modelo FORA do registry (oculto,
    # só do classificador) -> assume_model_exists exige provider explícito (:openai adapter). Os demais
    # seguem a validação normal contra o llm_models.json.
    chat = if provider.to_s == 'groq'
             context.chat(model: model, provider: :openai, assume_model_exists: true)
           else
             context.chat(model: model)
           end
    # Builder do ruby_llm (o construtor Chat.new não aceita temperature). to_f: a coluna é BigDecimal.
    chat.with_temperature(temperature.to_f) if temperature && chat.respond_to?(:with_temperature)
    chat.with_instructions(system_prompt) if chat.respond_to?(:with_instructions)
    # Tools NATIVAS de leitura (split Fase A single-call): o provider conduz o loop (pede tool -> a gem
    # chama #execute -> realimenta). Só quando passadas (nunca em shadow — o caller não anexa).
    chat.with_tools(*tools) if tools.present? && chat.respond_to?(:with_tools)
    chat = configure_output(chat, provider, json, schema)
    # Só passa `with:` no caminho de visão — o de texto fica idêntico ao anterior (sem mudança).
    response = image ? chat.ask(user_message, with: image) : chat.ask(user_message)
    {
      text: response.respond_to?(:content) ? response.content : response.to_s,
      tokens_in: response.try(:input_tokens).to_i,
      tokens_out: response.try(:output_tokens).to_i,
      # Prompt caching: tokens de ENTRADA servidos do cache do provider (subconjunto de input_tokens).
      # RubyLLM 1.9 expõe cached_tokens; try mantém compat se um provider não reportar (=> 0). Só MEDIÇÃO
      # por enquanto — estimate_cost ainda cobra input cheio (não sabemos o preço do token cacheado).
      cached_tokens: response.try(:cached_tokens).to_i,
      status: 'recorded'
    }
  rescue RubyLLM::UnauthorizedError => e
    # 401: chave inválida/revogada. Distinto do erro genérico para o Gateway poder cair no fallback da
    # chave global (BYOK — billing Fase 3). Não entra na lista de retry do ruby_llm (não é transiente).
    Rails.logger.error "[Ai::ModelRouter] UNAUTHORIZED: #{e.message}"
    { text: nil, tokens_in: 0, tokens_out: 0, status: 'error', error_type: 'auth_error', error: "#{e.class}: #{e.message}" }
  rescue StandardError => e
    Rails.logger.error "[Ai::ModelRouter] #{e.class}: #{e.message}"
    { text: nil, tokens_in: 0, tokens_out: 0, status: 'error', error_type: 'provider_error', error: "#{e.class}: #{e.message}" }
  end

  # Providers that honor the OpenAI-style `response_format: { type: 'json_object' }`. Anthropic and
  # Gemini use different mechanisms and OpenRouter only passes it through for some models, so we skip
  # them and rely on the tolerant parse_decision instead — never risk a "param desconhecido" error.
  JSON_FORMAT_PROVIDERS = %w[openai].freeze

  # Best-effort: asks OpenAI to emit a strict JSON object. Guarded by provider AND by respond_to?
  # (older RubyLLM may lack with_params); any failure degrades to the plain chat, never crashes.
  def self.apply_json_format(chat, provider)
    return chat unless JSON_FORMAT_PROVIDERS.include?(provider.to_s)
    return chat unless chat.respond_to?(:with_params)

    chat.with_params(response_format: { type: 'json_object' })
  rescue StandardError => e
    Rails.logger.warn "[Ai::ModelRouter] response_format ignorado: #{e.class}: #{e.message}"
    chat
  end

  # InstallationConfig/ENV que DESLIGA o structured output (fallback pro json_object). Padrão do projeto.
  DECISION_SCHEMA_CONFIG = 'AI_DECISION_SCHEMA'.freeze

  # Aplica a saída: Structured Output (strict) quando há schema + provider suporta with_schema; senão o
  # json_object de hoje. with_schema falhando degrada pro json_object (nunca quebra a chamada).
  def self.configure_output(chat, provider, json, schema)
    return chat unless json

    if schema && JSON_FORMAT_PROVIDERS.include?(provider.to_s) && chat.respond_to?(:with_schema)
      begin
        return chat.with_schema(schema)
      rescue StandardError => e
        Rails.logger.warn "[Ai::ModelRouter] with_schema falhou, cai no json_object: #{e.class}: #{e.message}"
      end
    end
    apply_json_format(chat, provider)
  end

  # Schema da decisão a usar (ou nil = json_object de hoje): só no caminho JSON, provider suportado e
  # com a feature LIGADA (default). Flag OFF via ENV['AI_DECISION_SCHEMA']='off' ou InstallationConfig.
  def self.decision_schema_for(provider, json)
    return nil unless json
    return nil unless JSON_FORMAT_PROVIDERS.include?(provider.to_s)
    return nil unless defined?(Ai::DecisionSchema)
    return nil unless decision_schema_enabled?

    Ai::DecisionSchema
  end

  # Default LIGADO; só desliga com valor 'off' (ENV vence, senão InstallationConfig). Fail-open (ligado).
  def self.decision_schema_enabled?
    raw = ENV['AI_DECISION_SCHEMA'].presence ||
          (InstallationConfig.find_by(name: DECISION_SCHEMA_CONFIG)&.value if defined?(InstallationConfig))
    raw.to_s.strip.downcase != 'off'
  rescue StandardError
    true
  end

  # Content do provider -> Hash de decisão. Com schema o ruby_llm já entregou Hash (JSON.parse interno);
  # sem schema é String -> parse tolerante (mantém a rede de segurança #unparsed). Único ponto de parse.
  def self.coerce_decision(text)
    return text if text.is_a?(Hash)

    parse_decision(text)
  end

  # Normaliza o envelope do Structured Output (campos achatados p/ o strict) de volta ao formato INTERNO.
  # Retrocompat: se vierem os campos ANTIGOS (attributes Hash, tool{name,input}), passam direto (flag OFF
  # com output legado). reply_text passa SEMPRE direto — o núcleo NÃO depende dele (transitório do 3b).
  def self.normalize_decision(data)
    return data unless data.is_a?(Hash)

    out = data.dup
    if data.key?('attributes_list')
      out['attributes'] = attributes_from_list(data['attributes_list'])
      out.delete('attributes_list')
    end
    if data.key?('tool_name') || data.key?('tool_input_json')
      tool = build_tool(data['tool_name'], data['tool_input_json'])
      tool.nil? ? out.delete('tool') : (out['tool'] = tool)
      out.delete('tool_name')
      out.delete('tool_input_json')
    end
    out
  end

  # attributes_list [{key,value}, ...] -> Hash { key => value }. Ignora itens sem chave. [] => {}.
  def self.attributes_from_list(list)
    return {} unless list.is_a?(Array)

    list.each_with_object({}) do |item, acc|
      next unless item.is_a?(Hash)

      key = item['key'].to_s.strip
      acc[key] = item['value'] unless key.empty?
    end
  end

  # tool_name + tool_input_json -> tool{ 'name', 'input' } (o formato que o Gateway espera), ou nil
  # (sem tool). tool_name vazio -> nil. tool_input_json inválido -> nil (tool IGNORADA) + log, sem crash.
  def self.build_tool(name, input_json)
    name = name.to_s.strip
    return nil if name.empty?

    input = parse_tool_input(input_json)
    return nil if input.nil? # JSON inválido -> ignora a ferramenta

    { 'name' => name, 'input' => input }
  end

  # STRING JSON do input -> Hash. Vazio -> {}. Não-objeto -> {}. Inválido -> nil (caller ignora a tool).
  def self.parse_tool_input(input_json)
    str = input_json.to_s.strip
    return {} if str.empty?

    parsed = JSON.parse(str)
    parsed.is_a?(Hash) ? parsed : {}
  rescue JSON::ParserError => e
    Rails.logger.warn "[Ai::ModelRouter] tool_input_json inválido, ferramenta ignorada: #{e.message}"
    nil
  end

  # Builds an ISOLATED per-call RubyLLM context carrying the provider/account key. It NEVER mutates the
  # global config (shared across Sidekiq threads — a global mutation leaks keys between tenants under
  # concurrency). RubyLLM.context dups the global config, so the endpoint/model-registry wiring
  # (Llm::Config) is inherited; only the key is overridden per call.
  # OpenAI is read from the account's "APIs & Credentials" (IntegrationSettingsService: account →
  # global → ENV), with the platform Captain key as fallback; the others read AI_<PROVIDER>_API_KEY
  # from InstallationConfig (or the matching ENV var).
  def self.provider_context(provider, account_id: nil, timeout: nil, force_global_key: false)
    case provider.to_s
    when 'anthropic'
      # BYOK: a chave própria da conta (Hub) vence; senão a global da SCNET. force_global_key força a global.
      key = byok_key(account_id, 'anthropic', force_global_key) || credential('AI_ANTHROPIC_API_KEY', 'ANTHROPIC_API_KEY')
      raise 'anthropic_api_key ausente (defina AI_ANTHROPIC_API_KEY ou ANTHROPIC_API_KEY)' if key.blank?

      build_context(timeout) { |c| c.anthropic_api_key = key }
    when 'google', 'gemini'
      key = byok_key(account_id, 'gemini', force_global_key) || credential('AI_GEMINI_API_KEY', 'GEMINI_API_KEY')
      raise 'gemini_api_key ausente' if key.blank?

      build_context(timeout) { |c| c.gemini_api_key = key }
    when 'openrouter'
      key = byok_key(account_id, 'openrouter', force_global_key) || credential('AI_OPENROUTER_API_KEY', 'OPENROUTER_API_KEY')
      raise 'openrouter_api_key ausente' if key.blank?

      build_context(timeout) { |c| c.openrouter_api_key = key }
    when 'groq'
      # Groq é OpenAI-compatible: reaproveita o adapter da OpenAI apontando o endpoint para api.groq.com
      # (sem client novo). A key própria da conta (BYOK) vence; senão AI_GROQ_API_KEY / GROQ_API_KEY.
      key = byok_key(account_id, 'groq', force_global_key) || credential('AI_GROQ_API_KEY', 'GROQ_API_KEY')
      raise 'groq_api_key ausente (defina AI_GROQ_API_KEY ou GROQ_API_KEY)' if key.blank?

      build_context(timeout) do |c|
        c.openai_api_key = key
        c.openai_api_base = 'https://api.groq.com/openai/v1'
      end
    else # openai
      # One-time endpoint/model-registry wiring (default OpenAI endpoint for most setups).
      Llm::Config.initialize! if defined?(Llm::Config)
      # Resolve the key per request — account Hub key wins, else the platform Captain key. force_global_key
      # (retry pós-falha de auth) ignora a chave da conta e vai direto na Captain.
      account_key = force_global_key ? nil : account_openai_key(account_id)
      key = account_key || credential('CAPTAIN_OPEN_AI_API_KEY', 'OPENAI_API_KEY')
      build_context(timeout) { |c| c.openai_api_key = key if key.present? }
    end
  end

  # BYOK (billing Fase 3): chave própria da conta para um provider de LLM, ou nil. force_global_key
  # curto-circuita (o retry pós-falha usa a chave global). O gate de feature vive em account_provider_key.
  def self.byok_key(account_id, provider, force_global_key)
    return nil if force_global_key

    account_provider_key(account_id, provider)
  end

  # Chave própria da conta (Hub: account→global→ENV) para o provider, SÓ se a conta tem a feature
  # custom_llm_api_key (fail-safe: mesmo que exista uma linha órfã no Hub, sem a feature não é usada).
  # Também é o ponto que o Gateway consulta para saber se a chamada usou chave própria (fallback).
  def self.account_provider_key(account_id, provider)
    return nil if account_id.blank? || !defined?(IntegrationSettingsService)

    account = Account.find_by(id: account_id)
    return nil unless account&.feature_enabled?('custom_llm_api_key')

    IntegrationSettingsService.get_config(account_id, provider.to_s)['apiKey'].presence
  rescue StandardError => e
    Rails.logger.warn "[Ai::ModelRouter] #{provider} key lookup falhou: #{e.class}: #{e.message}"
    nil
  end

  # Isolated per-call RubyLLM context (never mutates the global config). Applies an optional HTTP
  # request timeout in seconds — guarded because request_timeout= may not exist in every ruby_llm.
  def self.build_context(timeout)
    RubyLLM.context do |c|
      yield c
      c.request_timeout = timeout if timeout && c.respond_to?(:request_timeout=)
    end
  end

  # OpenAI key from the account's "APIs & Credentials" (integrations-hub), resolved account→global→ENV.
  def self.account_openai_key(account_id)
    return nil if account_id.blank? || !defined?(IntegrationSettingsService)

    IntegrationSettingsService.get_config(account_id, 'openai')['apiKey'].presence
  rescue StandardError => e
    Rails.logger.warn "[Ai::ModelRouter] openai key lookup falhou: #{e.class}: #{e.message}"
    nil
  end

  def self.credential(installation_name, env_name)
    value = (InstallationConfig.find_by(name: installation_name)&.value if defined?(InstallationConfig))
    value.presence || ENV.fetch(env_name, nil)
  rescue StandardError
    ENV.fetch(env_name, nil)
  end

  # When the model returns a parseable decision object we use it. When it DOESN'T (no JSON found or
  # malformed), we return decision 'unparsed' WITHOUT reply_text — never the raw text as a reply.
  # The Gateway turns 'unparsed' into an error run and dispatches nothing, so raw JSON/config the
  # model may emit instead of an answer can no longer leak to the customer (Bug 3).
  def self.parse_decision(text)
    return {} if text.blank?

    # Strip markdown code fences (```json ... ```) some providers add despite response_format, then
    # grab the JSON object. Unparseable -> decision 'unparsed' (Gateway dispatches nothing; Bug 3).
    json = strip_code_fences(text)[/\{.*\}/m]
    json ? JSON.parse(json) : { 'decision' => 'unparsed' }
  rescue JSON::ParserError
    { 'decision' => 'unparsed' }
  end

  def self.strip_code_fences(text)
    text.to_s.strip.sub(/\A```(?:\w*)\s*\n?/, '').sub(/\n?\s*```\s*\z/, '').strip
  end

  # [input, output] price per 1k tokens for a given model (first/most-specific substring match wins).
  def self.price_for(model)
    name = model.to_s.downcase
    table = price_table
    _, price = table[:prices].find { |pattern, _| name.include?(pattern) }
    price || table[:default]
  end

  def self.estimate_cost(model, tokens_in, tokens_out)
    input_price, output_price = price_for(model)
    ((tokens_in.to_i / 1000.0) * input_price + (tokens_out.to_i / 1000.0) * output_price).round(6)
  end

  # Cached price table: { default: [in, out], prices: [[match, [in, out]], ...] } (ordered).
  # Built from config/llm_prices.yml, then the AI_LLM_PRICES InstallationConfig override applied on
  # top. Cached for 1h so we don't read yml/DB on every run and every Costs-report row.
  def self.price_table
    Rails.cache.fetch(PRICES_CACHE_KEY, expires_in: PRICES_CACHE_TTL) { build_price_table }
  end

  # Drops the cache so an AI_LLM_PRICES change (or a redeploy of the yml) takes effect immediately.
  def self.reload_prices!
    Rails.cache.delete(PRICES_CACHE_KEY)
  end

  def self.build_price_table
    base = load_yaml_prices
    apply_price_override(base, load_override)
  end

  def self.load_yaml_prices
    raw = YAML.safe_load(File.read(Rails.root.join('config/llm_prices.yml')))
    {
      default: normalize_pair(raw['default']) || SAFETY_DEFAULT_PRICE,
      prices: Array(raw['prices']).filter_map { |row| price_entry(row) }
    }
  rescue StandardError => e
    Rails.logger.error "[Ai::ModelRouter] llm_prices.yml ilegível: #{e.class}: #{e.message}"
    { default: SAFETY_DEFAULT_PRICE, prices: [] }
  end

  # Parses the AI_LLM_PRICES InstallationConfig (JSON, same shape as the yml). Returns nil when
  # absent/blank/invalid so the yml stands alone.
  def self.load_override
    raw = (InstallationConfig.find_by(name: PRICES_CONFIG)&.value if defined?(InstallationConfig))
    return nil if raw.blank?

    parsed = raw.is_a?(String) ? JSON.parse(raw) : raw
    {
      default: normalize_pair(parsed['default']),
      prices: Array(parsed['prices']).filter_map { |row| price_entry(row) }
    }
  rescue StandardError => e
    Rails.logger.warn "[Ai::ModelRouter] AI_LLM_PRICES inválido, usando só o yml: #{e.class}: #{e.message}"
    nil
  end

  # Merge override onto base: same-match entries replace in place (keeping position/specificity);
  # brand-new matches are checked FIRST (specific hotfixes win); default overridden when provided.
  def self.apply_price_override(base, override)
    return base if override.nil?

    by_match = override[:prices].to_h
    merged = base[:prices].map { |match, price| [match, by_match[match] || price] }
    existing = base[:prices].map(&:first)
    fresh = override[:prices].reject { |match, _| existing.include?(match) }
    { default: override[:default] || base[:default], prices: fresh + merged }
  end

  # Normalizes one price row ({ 'match' =>, 'in' =>, 'out' => }) to [match, [in, out]]; nil if invalid.
  def self.price_entry(row)
    return nil unless row.is_a?(Hash)

    match = row['match'].to_s.downcase
    pair = normalize_pair([row['in'], row['out']])
    match.present? && pair ? [match, pair] : nil
  end

  # Coerces a [in, out] pair to two floats; nil if it isn't a usable pair.
  def self.normalize_pair(pair)
    return nil unless pair.is_a?(Array) && pair.size == 2 && pair.all? { |n| n.is_a?(Numeric) }

    [pair[0].to_f, pair[1].to_f]
  end
end
