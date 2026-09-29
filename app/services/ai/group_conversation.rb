# A IA NUNCA fala em grupo de WhatsApp. Grupo entra no sistema por mais de um caminho (webhook próprio
# da UazAPI e a integração nativa UazAPI→Chatwoot, que cria o contato do grupo numa inbox API), então
# a regra não pode depender de a entrada ter filtrado: todo ponto em que a IA roda ou envia pergunta aqui.
#
# Um grupo é reconhecido pelo JID "…@g.us" ou pelo id numérico longo (ex.: 120363…, 18 dígitos) — um
# telefone E.164 tem no máximo 15 dígitos, então nenhum contato 1:1 cai aqui.
class Ai::GroupConversation
  GROUP_JID_SUFFIX = '@g.us'.freeze
  MAX_PHONE_DIGITS = 15

  def self.group?(conversation)
    return false if conversation.nil?

    [conversation.contact_inbox&.source_id, conversation.contact&.identifier, conversation.contact&.phone_number]
      .any? { |id| group_id?(id.to_s) }
  end

  def self.group_id?(id)
    return true if id.include?(GROUP_JID_SUFFIX)

    id.match?(/\A\+?\d+\z/) && id.delete('+').length > MAX_PHONE_DIGITS
  end
end
