# Single source of truth for "may the AI send an outbound message to the customer now?".
# Shared by the Gateway (reactive reply) and the follow-up sweep (proactive nudge) so the
# canary / business-hours / kill-switch gates can never drift between the two paths.
class Ai::ReplyPolicy
  # The per-department auto_attendance toggle is the kill switch for every autonomous action.
  def self.acts_live?(mode, department)
    mode == 'live' && department.behavior.to_h['auto_attendance'] != false
  end

  def self.allowed?(mode:, department:, conversation:)
    return false unless acts_live?(mode, department)
    # Convive com o roteamento humano: se um agente já assumiu (assignee), a IA observa mas
    # NÃO envia (resposta/ferramenta/handoff) — não fala por cima do humano. Shadow segue observando.
    return false if conversation.assignee_id.present?

    behavior = department.behavior.to_h
    scope = behavior['reply_scope']
    return false if scope.blank? || scope == 'off'
    return false if outside_business_hours?(behavior, conversation)
    return true if scope == 'all'

    scope == 'canary' && behavior['canary_label'].present? &&
      conversation.cached_label_list_array.include?(behavior['canary_label'])
  end

  # F1.0/A — consolidated state the Gateway will read so the reply decision lives in one place.
  #   :off    -> the agent is not bound to this inbox (mode none): nothing runs
  #   :shadow -> observes and records, never replies (explicit shadow, or live but gated to silence)
  #   :live   -> may reply to the customer
  # A live-but-gated binding (reply_scope off, canary miss, off-hours, kill switch) still runs as
  # shadow: it records the decision without sending. Inert until the Gateway calls it (F1.1).
  def self.effective_reply_state(mode:, department:, conversation:)
    return :off if mode.blank? || mode == 'none'
    return :shadow if mode == 'shadow'

    allowed?(mode: mode, department: department, conversation: conversation) ? :live : :shadow
  end

  def self.skip_reason(mode:, department:, conversation:)
    return 'shadow_mode' unless mode == 'live'
    return 'auto_attendance_off' unless acts_live?(mode, department)
    return 'human_assigned' if conversation.assignee_id.present?

    behavior = department.behavior.to_h
    scope = behavior['reply_scope']
    return 'reply_scope_off' if scope.blank? || scope == 'off'
    return 'outside_business_hours' if outside_business_hours?(behavior, conversation)

    'canary_label_absent'
  end

  # When the toggle is on, respect the inbox's configured working hours: stay silent when closed.
  def self.outside_business_hours?(behavior, conversation)
    return false unless behavior.dig('business_hours', 'enabled')

    inbox = conversation.inbox
    inbox.respond_to?(:out_of_office?) && inbox.out_of_office?
  end
end
