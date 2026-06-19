# Internal capabilities = native Conexiia actions a Tool can resolve to. Each handler returns
# { output:, rollback_data: }; mutating handlers capture enough to undo via .rollback.
# Starts with the Comercial slice (read + update contact attributes); extend by adding handlers.
class Ai::CapabilityRegistry
  READ_ONLY = %w[contact.read].freeze

  def self.read_only?(key)
    READ_ONLY.include?(key.to_s)
  end

  def self.known?(key)
    respond_to?(handler_name(key))
  end

  # Executes the capability against the conversation. Returns { output:, rollback_data: }.
  def self.execute(key, conversation:, input:)
    raise "capability desconhecida: #{key}" unless known?(key)

    public_send(handler_name(key), conversation, (input || {}).with_indifferent_access)
  end

  # Best-effort undo for a recorded execution. Returns true if reverted.
  def self.rollback(execution)
    conversation = ::Conversation.find_by(id: execution.conversation_id)
    return false unless conversation

    case execution.capability_key
    when 'contact.update_attributes'
      conversation.contact&.update(custom_attributes: execution.rollback_data['custom_attributes'] || {})
      true
    else
      false
    end
  end

  # --- handlers (capability_key with '.' -> '_') ---

  def self.contact_read(conversation, _input)
    contact = conversation.contact
    {
      output: {
        'id' => contact&.id, 'name' => contact&.name,
        'phone_number' => contact&.phone_number, 'email' => contact&.email,
        'custom_attributes' => contact&.custom_attributes || {}
      },
      rollback_data: {}
    }
  end

  def self.contact_update_attributes(conversation, input)
    contact = conversation.contact
    raise 'conversa sem contato' if contact.nil?

    previous = contact.custom_attributes || {}
    merged = previous.merge(input.except('contact_id').to_h)
    contact.update!(custom_attributes: merged)
    { output: { 'custom_attributes' => merged }, rollback_data: { 'custom_attributes' => previous } }
  end

  def self.handler_name(key)
    key.to_s.tr('.', '_')
  end
end
