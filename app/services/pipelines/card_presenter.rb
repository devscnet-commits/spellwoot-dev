# JSON of a kanban card (a conversation) — lean on purpose: contact, owner, temperature, deal value,
# stage deadline (SLA) and the last chat message, batch-loaded for a whole column page.
class Pipelines::CardPresenter
  def self.many(conversations, flow)
    last_messages = last_messages_for(conversations.map(&:id))
    conversations.map { |conversation| new(conversation, flow, last_messages[conversation.id]).as_json }
  end

  def self.last_messages_for(conversation_ids)
    return {} if conversation_ids.empty?

    Message.where(conversation_id: conversation_ids, private: false, message_type: %i[incoming outgoing])
           .select('DISTINCT ON (messages.conversation_id) messages.*')
           .reorder(Arel.sql('messages.conversation_id, messages.created_at DESC'))
           .includes(:sender).index_by(&:conversation_id)
  end

  def initialize(conversation, flow, last_message = :load)
    @conversation = conversation
    @flow = flow
    @last_message = last_message == :load ? self.class.last_messages_for([conversation.id])[conversation.id] : last_message
  end

  def as_json(*)
    conversation_json.merge(
      deal_value: @flow.deal_value(@conversation), sla_due_at: @conversation.pipeline_sla_due_at&.to_i,
      sla_status: @conversation.pipeline_sla_status, contact: contact_json, assignee: assignee_json,
      team: @conversation.team&.slice(:id, :name), last_message: last_message_json,
      inbox: { id: @conversation.inbox_id, name: @conversation.inbox&.name, channel_type: @conversation.inbox&.channel_type }
    )
  end

  private

  def conversation_json
    {
      id: @conversation.display_id, conversation_id: @conversation.id, status: @conversation.status,
      priority: @conversation.priority, temperature: @conversation.temperature, stage_id: @conversation.pipeline_stage_id,
      stage_entered_at: @conversation.pipeline_stage_entered_at&.to_i, last_activity_at: @conversation.last_activity_at.to_i,
      created_at: @conversation.created_at.to_i, labels: @conversation.cached_label_list_array,
      custom_attributes: @conversation.custom_attributes.to_h
    }
  end

  def contact_json
    contact = @conversation.contact
    attrs = contact.additional_attributes.to_h
    location = [attrs['city'], attrs['state'].presence || attrs['region']].compact_blank.join(' - ').presence || attrs['country']
    { id: contact.id, name: contact.name, phone_number: contact.phone_number, email: contact.email,
      thumbnail: contact.avatar_url, location: location }
  end

  def assignee_json
    assignee = @conversation.assignee
    assignee && { id: assignee.id, name: assignee.name, thumbnail: assignee.avatar_url }
  end

  def last_message_json
    return if @last_message.nil?

    { content: @last_message.content.to_s.truncate(160), from: @last_message.incoming? ? 'contact' : 'agent',
      sender_name: @last_message.incoming? ? @conversation.contact.name : @last_message.sender.try(:name),
      created_at: @last_message.created_at.to_i }
  end
end
