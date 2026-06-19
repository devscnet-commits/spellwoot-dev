# Provider-agnostic model call driven by the operation profile (supervisor_provider/model).
# Reuses RubyLLM technically; configures the right provider key (the Chatwoot Llm::Config wires
# only OpenAI, so we wire the others here from InstallationConfig or ENV). Defensive: any failure
# returns an 'error' result + reason so the pipeline records the run instead of crashing.
class Ai::ModelRouter
  # Rough USD per 1k tokens [input, output]; refine with real pricing later.
  PRICES = {
    'claude' => [0.003, 0.015],
    'gpt'    => [0.0005, 0.0015],
    'gemini' => [0.0005, 0.0015]
  }.freeze

  def self.decide(profile:, system_prompt:, user_message:)
    provider = profile&.supervisor_provider.presence || 'anthropic'
    model    = profile&.supervisor_model.presence || 'claude-3-5-sonnet-latest'

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

  def self.estimate_cost(model, tokens_in, tokens_out)
    key = PRICES.keys.find { |k| model.to_s.downcase.include?(k) }
    return 0 unless key

    input_price, output_price = PRICES[key]
    ((tokens_in.to_i / 1000.0) * input_price + (tokens_out.to_i / 1000.0) * output_price).round(6)
  end
end
