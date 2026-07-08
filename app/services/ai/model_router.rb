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
    'openrouter' => 'openai/gpt-4.1-mini'
  }.freeze
  # Fallback quando não há profile (a coluna supervisor_temperature já nasce 0.3). Baixa = respostas
  # mais consistentes/determinísticas, adequado a atendimento.
  DEFAULT_TEMPERATURE = 0.3

  # json: opt-in to force a JSON-object response (OpenAI response_format). Only the supervisor
  # decision path sets it — its prompt always carries the JSON contract. Plain-text callers (e.g.
  # the department classifier) must leave it false so they aren't forced into JSON mode.
  def self.decide(profile:, system_prompt:, user_message:, provider: nil, model: nil, account_id: nil,
                  temperature: nil, json: false)
    # Default to openai: it reuses the platform's always-configured Captain key, so an agent with no
    # level (or a level missing a provider) still answers instead of crashing for an Anthropic key.
    provider = provider.presence || profile&.supervisor_provider.presence || 'openai'
    model    = model.presence || profile&.supervisor_model.presence || DEFAULT_MODELS.fetch(provider, 'gpt-4.1-mini')
    # Temperatura: um override cru explícito (ex.: confidence router) vence e passa direto; senão
    # traduz a POSIÇÃO abstrata do perfil (0-100) para a temperatura real do provider via
    # TemperatureMapper. Sem perfil, cai no default. `.nil?` (não ||) preserva um override 0.0.
    temperature = if !temperature.nil?
                    temperature
                  elsif profile
                    Ai::TemperatureMapper.resolve(provider, profile.temperature_position)
                  else
                    DEFAULT_TEMPERATURE
                  end

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    raw = call_model(provider: provider, model: model, system_prompt: system_prompt,
                     user_message: user_message, account_id: account_id, temperature: temperature, json: json)
    latency_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round

    decision = raw[:status] == 'error' ? { 'error' => raw[:error] } : parse_decision(raw[:text])

    {
      provider: provider,
      model: model,
      temperature: temperature.to_f,
      decision: decision,
      tokens_in: raw[:tokens_in],
      tokens_out: raw[:tokens_out],
      cost: estimate_cost(model, raw[:tokens_in], raw[:tokens_out]),
      latency_ms: latency_ms,
      status: raw[:status]
    }
  end

  # NOTE: validate the exact RubyLLM call shape when running; isolated here on purpose.
  # image: anexo para modelos de VISÃO (aceita ActiveStorage::Attached/Blob, path ou URL — o ruby_llm
  # resolve o tipo). nil = chamada de texto normal (comportamento inalterado: `with: nil` == sem anexo).
  def self.call_model(provider:, model:, system_prompt:, user_message:, account_id: nil, temperature: nil,
                      timeout: nil, json: false, image: nil)
    raise 'RubyLLM indisponível' unless defined?(RubyLLM)

    context = provider_context(provider, account_id: account_id, timeout: timeout)
    chat = context.chat(model: model)
    # Builder do ruby_llm (o construtor Chat.new não aceita temperature). to_f: a coluna é BigDecimal.
    chat.with_temperature(temperature.to_f) if temperature && chat.respond_to?(:with_temperature)
    chat.with_instructions(system_prompt) if chat.respond_to?(:with_instructions)
    chat = apply_json_format(chat, provider) if json
    # Só passa `with:` no caminho de visão — o de texto fica idêntico ao anterior (sem mudança).
    response = image ? chat.ask(user_message, with: image) : chat.ask(user_message)
    {
      text: response.respond_to?(:content) ? response.content : response.to_s,
      tokens_in: response.try(:input_tokens).to_i,
      tokens_out: response.try(:output_tokens).to_i,
      status: 'recorded'
    }
  rescue StandardError => e
    Rails.logger.error "[Ai::ModelRouter] #{e.class}: #{e.message}"
    { text: nil, tokens_in: 0, tokens_out: 0, status: 'error', error: "#{e.class}: #{e.message}" }
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

  # Builds an ISOLATED per-call RubyLLM context carrying the provider/account key. It NEVER mutates the
  # global config (shared across Sidekiq threads — a global mutation leaks keys between tenants under
  # concurrency). RubyLLM.context dups the global config, so the endpoint/model-registry wiring
  # (Llm::Config) is inherited; only the key is overridden per call.
  # OpenAI is read from the account's "APIs & Credentials" (IntegrationSettingsService: account →
  # global → ENV), with the platform Captain key as fallback; the others read AI_<PROVIDER>_API_KEY
  # from InstallationConfig (or the matching ENV var).
  def self.provider_context(provider, account_id: nil, timeout: nil)
    case provider.to_s
    when 'anthropic'
      key = credential('AI_ANTHROPIC_API_KEY', 'ANTHROPIC_API_KEY')
      raise 'anthropic_api_key ausente (defina AI_ANTHROPIC_API_KEY ou ANTHROPIC_API_KEY)' if key.blank?

      build_context(timeout) { |c| c.anthropic_api_key = key }
    when 'google', 'gemini'
      key = credential('AI_GEMINI_API_KEY', 'GEMINI_API_KEY')
      raise 'gemini_api_key ausente' if key.blank?

      build_context(timeout) { |c| c.gemini_api_key = key }
    when 'openrouter'
      key = credential('AI_OPENROUTER_API_KEY', 'OPENROUTER_API_KEY')
      raise 'openrouter_api_key ausente' if key.blank?

      build_context(timeout) { |c| c.openrouter_api_key = key }
    else # openai
      # One-time endpoint/model-registry wiring (default OpenAI endpoint for most setups).
      Llm::Config.initialize! if defined?(Llm::Config)
      # Resolve the key per request — account Hub key wins, else the platform Captain key.
      key = account_openai_key(account_id) || credential('CAPTAIN_OPEN_AI_API_KEY', 'OPENAI_API_KEY')
      build_context(timeout) { |c| c.openai_api_key = key if key.present? }
    end
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
