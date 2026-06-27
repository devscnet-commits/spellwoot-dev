# Invisible worker: produces a short rolling summary of the conversation for agent memory.
# Uses the operation profile's worker model if set, else the supervisor model. Read-only w.r.t.
# the customer; only writes our ai_agent_memory (done by the Gateway).
class Ai::Workers::Summary
  TRANSCRIPT_LIMIT = 12
  MIN_INCOMING = 2

  def self.generate(conversation:, agent:)
    return nil if conversation.messages.where(message_type: :incoming).count < MIN_INCOMING

    transcript = recent_transcript(conversation)
    return nil if transcript.blank?

    profile = agent.operation_profile
    raw = Ai::ModelRouter.call_model(
      provider: provider_for(profile),
      model: model_for(profile),
      system_prompt: 'Resuma a conversa em até 3 frases, em português, focando no que o cliente quer ' \
                     'e no estado do atendimento. Responda apenas o resumo.',
      user_message: transcript,
      account_id: agent.account_id
    )
    raw[:status] == 'error' ? nil : raw[:text].to_s.strip.presence
  rescue StandardError => e
    Rails.logger.error "[Ai::Workers::Summary] #{e.class}: #{e.message}"
    nil
  end

  def self.recent_transcript(conversation)
    conversation.messages
                .where(message_type: %i[incoming outgoing])
                .order(created_at: :desc).limit(TRANSCRIPT_LIMIT).to_a.reverse
                .map { |m| "#{m.incoming? ? 'Cliente' : 'Atendente'}: #{m.content}" }
                .join("\n")
  end

  def self.provider_for(profile)
    profile&.worker_overrides&.dig('summary_provider').presence ||
      profile&.supervisor_provider.presence || 'openai'
  end

  def self.model_for(profile)
    profile&.worker_overrides&.dig('summary_model').presence ||
      profile&.supervisor_model.presence || 'gpt-4.1-mini'
  end
end
