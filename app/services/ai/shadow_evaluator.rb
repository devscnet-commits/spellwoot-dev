# Audits one conversation against a Shadow's evaluation instructions via the model, recording a
# `shadow_eval` Ai::Run (no agent) + an event so the Validação screen surfaces the findings.
# Read-only: it never replies to the customer and never executes tools.
class Ai::ShadowEvaluator
  TRANSCRIPT_LIMIT = 30

  def initialize(shadow:, conversation:)
    @shadow = shadow
    @conversation = conversation
    @account = conversation.account
  end

  def evaluate
    run = Ai::Run.create!(
      account_id: @account.id, conversation_id: @conversation.id, inbox_id: @conversation.inbox_id,
      run_type: 'shadow_eval', mode: 'shadow', status: 'running'
    )
    result = Ai::ModelRouter.decide(profile: nil, system_prompt: build_prompt, user_message: transcript,
                                    account_id: @account.id)
    findings = (result[:decision] || {}).merge('shadow_id' => @shadow.id, 'shadow_name' => @shadow.name)
    run.update!(
      provider: result[:provider], model: result[:model], tokens_in: result[:tokens_in],
      tokens_out: result[:tokens_out], cost: result[:cost], latency_ms: result[:latency_ms],
      decision: findings, status: result[:status], error_type: normalize_error(findings['error_type'])
    )
    Ai::Event.create!(
      account_id: @account.id, conversation_id: @conversation.id, ai_run_id: run.id,
      event_type: 'shadow.evaluated', payload: findings
    )
    run
  end

  private

  def build_prompt
    parts = []
    parts << 'Você é um AVALIADOR de qualidade de atendimento (Shadow). Você NÃO responde ao ' \
             'cliente; apenas audita a conversa e aponta problemas e melhorias.'
    parts << "Instruções de avaliação:\n#{@shadow.instructions}" if @shadow.instructions.present?
    parts << 'Retorne ESTRITAMENTE um JSON válido: ' \
             '{"resolution":"knowledge|instruction|tool|transfer|closed|unanswered|error",' \
             '"confidence":0.0,"error_type":null,"issues":["..."],"suggestions":["..."]}'
    parts.join("\n\n")
  end

  def transcript
    @conversation.messages
                 .where(message_type: %i[incoming outgoing])
                 .order(created_at: :desc).limit(TRANSCRIPT_LIMIT).to_a.reverse
                 .map { |m| "#{m.incoming? ? 'Cliente' : 'Atendente'}: #{m.content}" }
                 .join("\n")
  end

  def normalize_error(type)
    Ai::Run::ERROR_TYPES.include?(type) ? type : nil
  end
end
