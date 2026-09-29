# Single source of truth for "may the AI send an outbound message to the customer now?".
# Shared by the Gateway (reactive reply) and the follow-up sweep (proactive nudge) so the
# canary / business-hours / kill-switch gates can never drift between the two paths.
class Ai::ReplyPolicy
  # The per-agent auto_attendance toggle is the kill switch for every autonomous action.
  def self.acts_live?(mode, agent)
    mode == 'live' && agent.behavior.to_h['auto_attendance'] != false
  end

  # bypass_handoff: pula SÓ os dois checks de "já foi entregue a um humano" (assignee/ai_handoff) —
  # usado pelo Gateway pra despachar a PRÓPRIA mensagem de encerramento do turno que acabou de decidir
  # a transferência (transferir_humano/on_complete handoff_human executam via uma request HTTP separada
  # — Api::Internal::AiExecuteToolController — e o @conversation.reload que o Gateway já precisa fazer
  # pra ver ai_step_index acaba trazendo ai_handoff/assignee_id junto; sem o bypass, o modelo nunca
  # entrega a mensagem que ele mesmo compôs avisando da transferência). NUNCA usado pra handoff que já
  # existia ANTES deste turno começar — só o Gateway decide quando é seguro (ver @acts_live).
  def self.allowed?(mode:, agent:, conversation:, bypass_handoff: false)
    return false unless acts_live?(mode, agent)
    return false if Conversations::GroupDetector.group?(conversation)
    return false if human_control_reason(conversation, bypass_handoff: bypass_handoff)

    behavior = agent.behavior.to_h
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
  def self.effective_reply_state(mode:, agent:, conversation:, bypass_handoff: false)
    return :off if mode.blank? || mode == 'none'
    return :shadow if mode == 'shadow'

    allowed?(mode: mode, agent: agent, conversation: conversation,
             bypass_handoff: bypass_handoff) ? :live : :shadow
  end

  def self.skip_reason(mode:, agent:, conversation:, bypass_handoff: false)
    return 'shadow_mode' unless mode == 'live'
    return 'auto_attendance_off' unless acts_live?(mode, agent)
    return 'group_conversation' if Conversations::GroupDetector.group?(conversation)
    reason = human_control_reason(conversation, bypass_handoff: bypass_handoff)
    return reason if reason

    behavior = agent.behavior.to_h
    scope = behavior['reply_scope']
    return 'reply_scope_off' if scope.blank? || scope == 'off'
    return 'outside_business_hours' if outside_business_hours?(behavior, conversation)

    'canary_label_absent'
  end

  # Por que a conversa está nas mãos de humanos (a IA observa, mas NÃO envia), ou nil. Lido do banco na hora
  # da decisão — não do objeto carregado no início do turno —, porque a atribuição/marcação pode acontecer
  # entre o enfileiramento e o envio (janela do agrupamento de mensagens).
  #   ai_disabled_attribute: atributo "desativa_ia" marcado na conversa — vale sempre, até no handoff.
  #   human_engaged: um humano de verdade já respondeu.
  #   assigned_in_panel: um atendente foi atribuído PELO PAINEL (Conversations::AssignmentsController).
  #     Atribuição por API/automação (n8n, Bitrix — dono do CRM) não conta: ela chega segundos depois do
  #     lead e calaria a IA em todo lead pago (achado 14/09).
  #   handed_off: já entregue a um humano (handoff), mesmo antes de a atribuição concluir.
  def self.human_control_reason(conversation, bypass_handoff: false)
    assignee_id, additional, custom = ::Conversation.where(id: conversation.id)
                                                    .pick(:assignee_id, :additional_attributes, :custom_attributes)
    return 'ai_disabled_attribute' if ActiveModel::Type::Boolean.new.cast(custom.to_h['desativa_ia'])
    return if bypass_handoff
    return 'human_engaged' if human_engaged?(conversation)
    return 'assigned_in_panel' if assignee_id.present? && additional.to_h['ai_panel_assignee_id'] == assignee_id

    'handed_off' if additional.to_h['ai_handoff']
  end

  # A real Chatwoot agent's outgoing message has sender_type "User" — the AI's own replies go out
  # with no sender (Ai::ActionDispatcher#send_message), and other bots use "AgentBot"/
  # "Captain::Assistant", so this only catches an actual person having typed into the conversation.
  # private: false is essential (same filter as ActionService#last_responding_agent_id): integrations
  # post internal notes as a User — a Bitrix "Negócio registrado" note silenced the AI on every paid
  # lead until this was added (found live 15/09). A note isn't talking to the customer.
  def self.human_engaged?(conversation)
    conversation.messages.outgoing.where(sender_type: 'User', private: false).exists?
  end

  # When the toggle is on, respect the inbox's configured working hours: stay silent when closed.
  def self.outside_business_hours?(behavior, conversation)
    return false unless behavior.dig('business_hours', 'enabled')

    inbox = conversation.inbox
    inbox.respond_to?(:out_of_office?) && inbox.out_of_office?
  end
end
