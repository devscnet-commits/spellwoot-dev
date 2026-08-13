# Refreshes the persistent per-contact memory (Ai::CustomerMemory) whenever a conversation is
# resolved, so the next conversation starts already knowing this customer. Gated by the ai_core
# feature; skips conversations without a contact. Mirrors Ai::ShadowListener's hook.
class Ai::CustomerMemoryListener < BaseListener
  def conversation_resolved(event)
    conversation = extract_conversation_and_account(event)[0]
    return if conversation.blank? || conversation.contact_id.blank?
    return unless conversation.account&.feature_enabled?('ai_core')

    Ai::CustomerMemoryJob.perform_later(conversation.id)
  end
end
