# Extraído do Ai::Gateway (quebra do God object — Passo 3): executa as AÇÕES do pipeline — responder o
# cliente (reply) e rodar capabilities nativas auditadas (transfer/resolve), com o gate live/shadow.
# NÃO decide QUE ação tomar (isso é do dispatch no Gateway) — só EXECUTA e registra (ai_events +
# CapabilityExecution). Contexto do run injetado no initialize; `run` (o Ai::Run) passa por método,
# pois só a CapabilityExecution precisa dele (ai_run_id). Emite os MESMOS ai_events de antes.
#
# ATENÇÃO: recebe `acts_live` por injeção — logo o Gateway só pode criar este dispatcher DEPOIS de
# resolver @acts_live (após o department). Todos os call-sites do run são posteriores a isso.
class Ai::ActionDispatcher
  def initialize(conversation:, account:, mode:, acts_live:)
    @conversation = conversation
    @account = account
    @mode = mode
    @acts_live = acts_live
  end

  # Why an action was not executed: shadow binding, the department toggle off, or a missing tool.
  def not_acting_reason(tool = :present)
    return 'shadow_mode' unless @mode == 'live'
    return 'auto_attendance_off' unless @acts_live

    tool.nil? ? 'tool_not_found' : 'auto_attendance_off'
  end

  # Executes a native action in live mode (audited) or records intention otherwise.
  def execute_action(capability_key, input, run, label, extra: {})
    unless @acts_live
      emit("#{label}.intended", extra.merge(executed: false, reason: not_acting_reason))
      return
    end

    output = Ai::CapabilityRegistry.execute(capability_key, conversation: @conversation, input: input)
    Ai::CapabilityExecution.create!(
      account_id: @account.id, conversation_id: @conversation.id, ai_run_id: run.id,
      capability_key: capability_key, input: input, output: output[:output], status: 'executed',
      governance: 'allowed', rollback_data: output[:rollback_data], requested_by: 'ai'
    )
    emit("#{label}.executed", extra.merge(executed: true))
  rescue StandardError => e
    Rails.logger.error "[Ai::ActionDispatcher##{label}] #{e.class}: #{e.message}"
    emit("#{label}.failed", { error: "#{e.class}: #{e.message}" })
  end

  # Sends the AI reply to the customer — the only outward-facing action. Gated by the department
  # reply_scope (off by default): 'all' replies to every live conversation, 'canary' only when the
  # conversation carries the configured label. Shadow / off / missing label records intention only.
  def reply(department, text)
    return if text.blank?

    # Safety cap: stop replying after the department's max number of AI replies in this
    # conversation (0 = no limit). Counts 'reply.sent' events, so human agent replies don't count.
    max_replies = department.behavior.to_h['max_replies'].to_i
    if max_replies.positive? && ai_replies_count >= max_replies
      emit('reply.skipped', { reason: 'max_replies_reached', max: max_replies })
      return
    end

    state = Ai::ReplyPolicy.effective_reply_state(mode: @mode, department: department, conversation: @conversation)
    if state == :live
      Messages::MessageBuilder.new(nil, @conversation, { content: text, private: false }).perform
      emit('reply.sent', { chars: text.length })
    else
      reason = Ai::ReplyPolicy.skip_reason(mode: @mode, department: department, conversation: @conversation)
      emit('reply.intended', { executed: false, reason: reason })
    end
  rescue StandardError => e
    Rails.logger.error "[Ai::ActionDispatcher#reply] #{e.class}: #{e.message}"
    emit('reply.failed', { error: "#{e.class}: #{e.message}" })
  end

  private

  # Number of AI replies already sent in this conversation (across runs/agents).
  def ai_replies_count
    Ai::Event.where(conversation_id: @conversation.id, event_type: 'reply.sent').count
  end

  # Espelha o Ai::Gateway#emit: grava o ai_event na MESMA stream (account/conversation), com
  # ai_run_id nil (os eventos de reply/action nunca setavam run_id) — preserva o golden master.
  def emit(type, payload)
    Ai::Event.create!(
      account_id: @account.id, conversation_id: @conversation.id,
      ai_run_id: nil, event_type: type, payload: payload, status: 'ok'
    )
  end
end
