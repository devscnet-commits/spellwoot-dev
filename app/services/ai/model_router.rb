# Provider-agnostic model call driven by the operation profile (supervisor_provider/model).
# Reuses RubyLLM technically (already a dependency). Defensive: on any failure it returns an
# 'error' result so the pipeline still records the run instead of crashing.
class Ai::ModelRouter
  # Rough USD per 1k tokens [input, output]; refine with real pricing later.
  PRICES = {
    'claude' => [0.003, 0.015],
    'gpt'    => [0.0005, 0.0015],
    'gemini' => [0.0005, 0.0015]
  }.freeze

  def self.decide(profile:, system_prompt:, user_message:)
    provider = profile&.supervisor_provider.presence || 'anthropic'
    model    = profile&.supervisor_model.presence || 'claude-3-5-sonnet'

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    raw = call_model(model: model, system_prompt: system_prompt, user_message: user_message)
    latency_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round

    {
      provider: provider,
      model: model,
      decision: parse_decision(raw[:text]),
      tokens_in: raw[:tokens_in],
      tokens_out: raw[:tokens_out],
      cost: estimate_cost(model, raw[:tokens_in], raw[:tokens_out]),
      latency_ms: latency_ms,
      status: raw[:status]
    }
  end

  # NOTE: validate the exact RubyLLM call shape when running in the app; isolated here on purpose.
  def self.call_model(model:, system_prompt:, user_message:)
    raise 'RubyLLM indisponível' unless defined?(RubyLLM)

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
    { text: nil, tokens_in: 0, tokens_out: 0, status: 'error' }
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
