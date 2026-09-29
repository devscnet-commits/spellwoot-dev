# A IA NUNCA fala em grupo de WhatsApp. Grupo entra no sistema por mais de um caminho (webhook próprio
# da UazAPI e a integração nativa UazAPI→Chatwoot, que cria o contato do grupo numa inbox API), então
# a regra não pode depender de a entrada ter filtrado: todo ponto em que a IA roda ou envia pergunta aqui.
#
# Um grupo é reconhecido pelo JID "…@g.us". O id numérico longo (ex.: 120363…, 18 dígitos — telefone
# E.164 tem no máximo 15) só vale em inbox de WhatsApp: no Facebook/Instagram o id do cliente (PSID/IGSID)
# também tem 16–17 dígitos e NÃO é grupo.
#
# Ponto único de decisão: se um dia a IA puder atender grupo, a opção entra aqui.
class Ai::GroupConversation
  GROUP_JID_SUFFIX = '@g.us'.freeze
  MAX_PHONE_DIGITS = 15

  def self.group?(conversation)
    return false if conversation.nil?

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
