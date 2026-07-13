# Dispara a geração do resumo de handoff em background (enfileirado por Ai::HandoffCoordinator#assign_human
# quando o handoff é AUTOMÁTICO da IA — reason presente). Fora do caminho síncrono do handoff: se a
# geração demorar/falhar, o handoff (transfer + atribuição) já aconteceu e não é afetado.
class Ai::HandoffSummaryJob < ApplicationJob
  queue_as :low

  def perform(conversation_id, reason)
    conversation = Conversation.find_by(id: conversation_id)
    return if conversation.nil?

    Ai::HandoffSummaryGenerator.new(conversation: conversation, reason: reason).generate
  end
end
