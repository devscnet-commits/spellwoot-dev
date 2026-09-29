# Reconhece conversa de grupo de WhatsApp. Grupo entra no sistema por mais de um caminho (integração nativa
# UazAPI→Chatwoot, que cria o contato do grupo numa inbox API, e o webhook próprio da UazAPI), então a regra
# não depende de a entrada ter filtrado.
#
# A conversa nasce marcada (Conversation#group_chat) e é por essa marca que a lista separa a aba "Grupos",
# a distribuição automática, o CSAT e os relatórios deixam o grupo de fora. A IA pergunta aqui também:
# nunca responde grupo — só humanos.
#
# Um grupo é reconhecido pelo JID "…@g.us". O id numérico longo (ex.: 120363…, 18 dígitos — telefone E.164
# tem no máximo 15) só vale em inbox de WhatsApp: no Facebook/Instagram o id do cliente (PSID/IGSID) também
# tem 16–17 dígitos e NÃO é grupo.
#
# Ponto único de decisão: se um dia a IA puder atender grupo, a opção entra em Ai::* lendo esta marca.
class Conversations::GroupDetector
  GROUP_JID_SUFFIX = '@g.us'.freeze
  MAX_PHONE_DIGITS = 15

  def self.group?(conversation)
    return false if conversation.nil?

    conversation.group_chat? || detect(conversation)
  end

  def self.detect(conversation)
    ids = contact_ids(conversation)
    return true if ids.any? { |id| id.include?(GROUP_JID_SUFFIX) }

    whatsapp_inbox?(conversation.inbox) && ids.any? { |id| long_numeric_id?(id) }
  end

  def self.contact_ids(conversation)
    contact = conversation.contact
    [conversation.contact_inbox&.source_id, contact&.identifier, contact&.phone_number].map(&:to_s)
  end

  def self.long_numeric_id?(id)
    id.match?(/\A\+?\d+\z/) && id.delete('+').length > MAX_PHONE_DIGITS
  end

  def self.whatsapp_inbox?(inbox)
    return false if inbox.nil?
    return true if inbox.channel_type == 'Channel::Whatsapp'

    inbox.channel_type == 'Channel::Api' && inbox.channel.additional_attributes.to_h['uazapi_instance_token'].present?
  end
end
