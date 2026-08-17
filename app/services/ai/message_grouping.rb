# Debounce/grouping for inbound customer messages. When a department sets a grouping delay, the
# Gateway run is deferred and only the LAST message of a burst is processed, with the burst's text
# grouped — so the AI replies once to "olá / quero a 2ª via / do contrato X" instead of three times.
module Ai
  module MessageGrouping
    module_function

    # Grouping delay (seconds). Uses the conversation's CURRENT step delay when set (tracked by the
    # Gateway in additional_attributes['ai_step']); otherwise the department's general delay.
    # nil (unset) = falls back to the general delay. 0 (explicit) = no grouping on THIS step, even
    # when the department has a general delay — so a step can opt out of grouping on purpose.
    def delay_seconds(inbox_id, conversation: nil)
      per_step = conversation&.additional_attributes&.dig('ai_step', 'grouping_delay_seconds')
      return per_step.to_i unless per_step.nil?

      general_delay(inbox_id)
    end

    # Max general grouping delay across the default departments of the agents attending this inbox.
    def general_delay(inbox_id)
      agent_ids = Ai::AgentInbox.where(inbox_id: inbox_id, active: true).pluck(:ai_agent_id)
      return 0 if agent_ids.empty?

      Ai::Department.where(ai_agent_id: agent_ids, is_default: true)
                    .map { |dept| dept.behavior.to_h.dig('grouping', 'delay_seconds').to_i }
                    .push(0).max
    end

    # True when no newer incoming message exists — i.e. the customer went quiet.
    def latest_incoming?(message)
      !message.conversation.messages.incoming.where('messages.id > ?', message.id).exists?
    end

    # The customer's burst: incoming messages since the last outgoing message, joined.
    def grouped_content(conversation)
      last_outgoing_id = conversation.messages.outgoing.maximum(:id) || 0
      conversation.messages.incoming
                  .where('messages.id > ?', last_outgoing_id)
                  .order(:id).pluck(:content).compact_blank.join("\n").strip
    end
  end
end
