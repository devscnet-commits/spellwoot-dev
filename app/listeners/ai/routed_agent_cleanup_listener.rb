# Limpa a posse forçada de IA (additional_attributes['ai_routed_agent_id']) quando a conversa é RESOLVIDA —
# a fase de IA acabou. É um dos pontos de limpeza da posse IA→IA (ver Ai::HandoffCoordinator#route_to_ai):
# sem ele, uma conversa REABERTA depois de resolvida reentraria FORÇADA na IA de destino em vez de cair na
# eleição normal. (Reabrir não precisa de tratamento extra: a marca já foi limpa aqui, então o GatewayRunJob
# não acha marca e roteia normalmente — nunca fica órfã.) Gated por ai_core; no-op sem a marca.
class Ai::RoutedAgentCleanupListener < BaseListener
  def conversation_resolved(event)
    conversation = extract_conversation_and_account(event)[0]
    return if conversation.blank?
    return unless conversation.account&.feature_enabled?('ai_core')

    attrs = conversation.additional_attributes || {}
    return unless attrs.key?('ai_routed_agent_id')

    attrs.delete('ai_routed_agent_id')
    conversation.update!(additional_attributes: attrs)
  end
end
