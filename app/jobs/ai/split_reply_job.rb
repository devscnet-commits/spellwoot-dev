# Cria UMA parte de uma resposta quebrada (modo "Agir como humano"). O Ai::ActionDispatcher envia a
# 1ª parte na hora e AGENDA as demais com delay incremental (Sidekiq scheduled), para chegarem como
# várias mensagens curtas em sequência — simulando alguém digitando.
#
# Só cria a mensagem; NÃO emite reply.sent (o dispatcher já emitiu uma vez para a resposta inteira),
# então max_replies/métricas não são multiplicados pelo número de partes.
class Ai::SplitReplyJob < ApplicationJob
  queue_as :default

  def perform(conversation_id, content)
    conversation = Conversation.find_by(id: conversation_id)
    return if conversation.nil? || content.blank?

    Messages::MessageBuilder.new(nil, conversation, { content: content, private: false }).perform
  end
end
