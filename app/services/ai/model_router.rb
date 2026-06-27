# Provider-agnostic model call driven by the operation profile (supervisor_provider/model).
# Reuses RubyLLM technically; configures the right provider key (the Chatwoot Llm::Config wires
# only OpenAI, so we wire the others here from InstallationConfig or ENV). Defensive: any failure
# returns an 'error' result + reason so the pipeline records the run instead of crashing.
class Ai::ModelRouter
  # List prices in USD per 1k tokens [input, output], most specific match first.
  # Source: public provider price sheets. These are estimates — review periodically
  # (caching, batch discounts, image tokens and FX are not reflected here).
  PRICES = [
    ['claude-3-5-haiku',  [0.0008, 0.004]],
    ['claude-3-haiku',    [0.00025, 0.00125]],
    ['claude-haiku',      [0.0008, 0.004]],
    ['claude-3-opus',     [0.015, 0.075]],
    ['claude-opus',       [0.015, 0.075]],
    ['claude-3-5-sonnet', [0.003, 0.015]],
    ['claude-sonnet',     [0.003, 0.015]],
    ['claude',            [0.003, 0.015]],
    ['gpt-4o-mini',       [0.00015, 0.0006]],
    ['gpt-4o',            [0.0025, 0.01]],
    ['gpt-4.1-nano',      [0.0001, 0.0004]],
    ['gpt-4.1-mini',      [0.0004, 0.0016]],
    ['gpt-4.1',           [0.002, 0.008]],
    ['o4-mini',           [0.0011, 0.0044]],
    ['o3-mini',           [0.0011, 0.0044]],
    ['gpt',               [0.0005, 0.0015]],
    ['gemini-2.0-flash',  [0.000075, 0.0003]],
    ['gemini-1.5-flash',  [0.000075, 0.0003]],
    ['gemini-flash',      [0.000075, 0.0003]],
    ['gemini-1.5-pro',    [0.00125, 0.005]],
    ['gemini-pro',        [0.00125, 0.005]],
    ['gemini',            [0.0005, 0.0015]]
  ].freeze
  # Fallback when the model name matches nothing above (still an estimate, never 0).
  DEFAULT_PRICE = [0.001, 0.003].freeze

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

  def self.decide(profile:, system_prompt:, user_message:, provider: nil, model: nil)
    # Default to openai: it reuses the platform's always-configured Captain key, so an agent with no
    # level (or a level missing a provider) still answers instead of crashing for an Anthropic key.
    provider = provider.presence || profile&.supervisor_provider.presence || 'openai'
    model    = model.presence || profile&.supervisor_model.presence || DEFAULT_MODELS.fetch(provider, 'gpt-4.1-mini')

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    raw = call_model(provider: provider, model: model, system_prompt: system_prompt, user_message: user_message)
    latency_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round

    decision = raw[:status] == 'error' ? { 'error' => raw[:error] } : parse_decision(raw[:text])

    {
      provider: provider,
      model: model,
      decision: decision,
      tokens_in: raw[:tokens_in],
      tokens_out: raw[:tokens_out],
      cost: estimate_cost(model, raw[:tokens_in], raw[:tokens_out]),
      latency_ms: latency_ms,
      status: raw[:status]
    }
  end

  # NOTE: validate the exact RubyLLM call shape when running; isolated here on purpose.
  def self.call_model(provider:, model:, system_prompt:, user_message:)
    raise 'RubyLLM indisponível' unless defined?(RubyLLM)

    configure_provider!(provider)
    chat = RubyLLM.chat(model: model)
    chat.with_instructions(system_prompt) if chat.respond_to?(:with_instructions)
    response = chat.ask(user_message)
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

  # Wires the API key for the chosen provider. OpenAI reuses Chatwoot's existing Llm::Config;
  # the others read AI_<PROVIDER>_API_KEY from InstallationConfig (or the matching ENV var).
  def self.configure_provider!(provider)
    case provider.to_s
    when 'anthropic'
      key = credential('AI_ANTHROPIC_API_KEY', 'ANTHROPIC_API_KEY')
      raise 'anthropic_api_key ausente (defina AI_ANTHROPIC_API_KEY ou ANTHROPIC_API_KEY)' if key.blank?

      RubyLLM.configure { |c| c.anthropic_api_key = key }
    when 'google', 'gemini'
      key = credential('AI_GEMINI_API_KEY', 'GEMINI_API_KEY')
      raise 'gemini_api_key ausente' if key.blank?

      RubyLLM.configure { |c| c.gemini_api_key = key }
    when 'openrouter'
      key = credential('AI_OPENROUTER_API_KEY', 'OPENROUTER_API_KEY')
      raise 'openrouter_api_key ausente' if key.blank?

      RubyLLM.configure { |c| c.openrouter_api_key = key }
    else # openai: reuse the platform's existing configuration (CAPTAIN_OPEN_AI_API_KEY)
      Llm::Config.initialize! if defined?(Llm::Config)
    end
  end

  def self.credential(installation_name, env_name)
    value = (InstallationConfig.find_by(name: installation_name)&.value if defined?(InstallationConfig))
    value.presence || ENV.fetch(env_name, nil)
  rescue StandardError
    ENV.fetch(env_name, nil)
  end

  def self.parse_decision(text)
    return {} if text.blank?

    json = text[/\{.*\}/m]
    json ? JSON.parse(json) : { 'decision' => 'reply', 'reply_text' => text }
  rescue JSON::ParserError
    { 'decision' => 'reply', 'reply_text' => text }
  end

  # [input, output] price per 1k tokens for a given model (longest/most-specific match wins).
  def self.price_for(model)
    name = model.to_s.downcase
    _, price = PRICES.find { |pattern, _| name.include?(pattern) }
    price || DEFAULT_PRICE
  end

  def self.estimate_cost(model, tokens_in, tokens_out)
    input_price, output_price = price_for(model)
    ((tokens_in.to_i / 1000.0) * input_price + (tokens_out.to_i / 1000.0) * output_price).round(6)
  end
end
