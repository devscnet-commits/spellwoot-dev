# Account-scoped, dev-time prompt/step-instructions assistant. Suggestion-only; nothing is sent to
# any customer. Uses ::Ai::PromptAssistant (top-level) to avoid namespace collision.
class Api::V1::Accounts::AiPromptAssistantController < Api::V1::Accounts::BaseController
  RATE_LIMIT = 10   # requisições
  RATE_WINDOW = 60  # segundos (janela fixa por conta)

  def create
    if throttled?
      return render(json: { error: 'muitas requisições, tente novamente em instantes' },
                    status: :too_many_requests)
    end

    render json: ::Ai::PromptAssistant.new(
      account: Current.account, kind: params[:kind], brief: params[:brief],
      agent: scoped_agent, requested_by: Current.user&.id
    ).suggest
  end

  private

  # O agente ancora as CAPACIDADES REAIS (tools/knowledge/variáveis) que o assistente usa para não
  # inventar consulta sem fonte. Escopado à conta (nunca confia no id cru); ausente => o service degrada.
  def scoped_agent
    id = params[:agent_id]
    return if id.blank?

    ::Ai::Agent.find_by(id: id, account_id: Current.account.id)
  end

  # Rate limit de janela fixa por conta (Redis). Best-effort: se o Redis falhar, NÃO bloqueia.
  def throttled?
    key = "ai_prompt_assistant:throttle:#{Current.account.id}"
    count = Redis::Alfred.incr(key)
    Redis::Alfred.expire(key, RATE_WINDOW) if count == 1
    count > RATE_LIMIT
  rescue StandardError => e
    Rails.logger.error "[AiPromptAssistantController#throttled?] #{e.class}: #{e.message}"
    false
  end
end
