# Nova rodada da IA depois de uma busca de conhecimento que falhou (Ai::Gateway#schedule_knowledge_retry).
# No turno anterior a IA avisou o cliente que estava consultando e voltaria com a resposta; esta rodada
# é o que faz isso ser verdade. Roda o Ai::Gateway de novo para a mesma mensagem, com uma instrução
# de sistema pedindo para consultar de novo e responder a pergunta pendente.
#
# Não roda quando o cliente já mandou outra mensagem (o turno dela já responde, com o contexto novo) ou
# quando o binding deixou de estar ativo. Handoff/fora de horário/etc. continuam decididos pelo próprio
# Gateway (Ai::ReplyPolicy) — se um humano assumiu, a IA não fala.
class Ai::KnowledgeRetryJob < ApplicationJob
  queue_as :medium

  # Espera antes de cada nova rodada; o tamanho da lista é o número máximo de rodadas.
  DELAYS = [30.seconds, 2.minutes, 5.minutes].freeze

  RETRY_INSTRUCTION = '[Mensagem automática do sistema, não do cliente] Há pouco a consulta à base de ' \
                      'conhecimento falhou e você avisou o cliente que já voltaria com a resposta. Consulte ' \
                      'a base de conhecimento de novo agora e responda a pergunta pendente do cliente, sem ' \
                      'cumprimentar de novo. Última mensagem do cliente: '.freeze

  def perform(message_id, agent_inbox_id, attempt)
    message = Message.find_by(id: message_id)
    binding = Ai::AgentInbox.agent_active.find_by(id: agent_inbox_id, active: true)
    return if message.blank? || binding.blank?
    return unless Ai::MessageGrouping.latest_incoming?(message)

    Ai::Gateway.new(
      message: message, agent_inbox: binding, mode: binding.mode,
      content_override: "#{RETRY_INSTRUCTION}\"#{message.content}\"",
      knowledge_retry_attempt: attempt
    ).run
  end
end
