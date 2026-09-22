# Refreshes the persistent per-contact memory (Ai::CustomerMemory) whenever a conversation is
# resolved, so the next conversation starts already knowing this customer. Gated by the ai_core
# feature; skips conversations without a contact. Mirrors Ai::ShadowListener's hook.
class Ai::CustomerMemoryListener < BaseListener
  def conversation_resolved(event)
    conversation = extract_conversation_and_account(event)[0]
    return if conversation.blank? || conversation.contact_id.blank?
    return unless conversation.account&.feature_enabled?('ai_core')
    return unless ai_works_this_inbox?(conversation.inbox_id)

    Ai::CustomerMemoryJob.perform_later(conversation.id)
  end

  private

  # A memória só é LIDA por um turno de IA (Ai::Gateway injeta no prompt). Numa caixa sem nenhuma IA
  # vinculada ninguém nunca vai lê-la, então a chamada ao modelo por conversa resolvida era gasto
  # puro — e caía também em caixa de atendimento humano e de grupo, que é onde ela mais aparecia.
  #
  # O critério é a CAIXA ter IA ativa, não esta conversa ter sido atendida por IA: numa caixa com IA
  # o mesmo contato volta a falar com ela, então vale memorizar até o que um humano atendeu hoje.
  def ai_works_this_inbox?(inbox_id)
    Ai::AgentInbox.exists?(inbox_id: inbox_id, active: true)
  end
end
