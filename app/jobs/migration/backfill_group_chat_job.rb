# Marca como grupo (Conversation#group_chat) as conversas de grupo de WhatsApp que já existiam antes da marca.
# Pré-filtra no banco os contatos com cara de grupo (JID @g.us ou id com mais de 15 dígitos) e confirma cada
# um no Conversations::GroupDetector — a mesma regra que marca as conversas novas.
class Migration::BackfillGroupChatJob < ApplicationJob
  queue_as :low

  CANDIDATES_SQL = <<~SQL.squish.freeze
    contacts.identifier LIKE '%@g.us%' OR contact_inboxes.source_id LIKE '%@g.us%'
    OR length(regexp_replace(coalesce(contacts.identifier, ''), '\\D', '', 'g')) > 15
    OR length(regexp_replace(coalesce(contacts.phone_number, ''), '\\D', '', 'g')) > 15
    OR length(regexp_replace(coalesce(contact_inboxes.source_id, ''), '\\D', '', 'g')) > 15
  SQL

  def perform
    Conversation.where(group_chat: false).joins(:contact).left_joins(:contact_inbox).where(CANDIDATES_SQL)
                .preload(:contact, :contact_inbox, inbox: :channel).find_each do |conversation|
      conversation.update_column(:group_chat, true) if Conversations::GroupDetector.detect(conversation) # rubocop:disable Rails/SkipsModelValidations
    end
  end
end
