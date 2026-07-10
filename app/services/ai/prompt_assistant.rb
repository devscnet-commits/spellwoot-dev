# Dev-time helper that suggests good prompts. Given a free-text brief from the user, generates ONE
# text suggestion for either an agent base_prompt or a playbook step's instructions. Suggestion-only
# (the UI never auto-fills — the user copies if they like it). NOT tied to a conversation/agent: it's
# account-scoped. Reuses Ai::ModelRouter (cheap fixed model) and records an Ai::Run for audit/cost —
# consuming the account's AI credits like every other AI call.
class Ai::PromptAssistant
  MODEL = 'gpt-4.1-mini'
  KINDS = %w[base_prompt step_instructions].freeze

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

  # PROVISÓRIO (Commit 1) — só para validar o fluxo end-to-end. O conteúdo real (com as regras
  # anti-loop derivadas do bug investigado) entra no Commit 2.
  def system_prompt(kind)
    alvo = kind == 'base_prompt' ? 'o prompt base de um agente de IA de atendimento' : 'as instruções de uma etapa de atendimento'
    "Gere #{alvo} a partir do pedido do usuário. Retorne ESTRITAMENTE um JSON válido, " \
      'sem texto fora dele: {"suggestion":"<o texto gerado>"}.'
  end
end
