# Extraído do Ai::Gateway (quebra do God object — Passo 3): executa as AÇÕES do pipeline — responder o
# cliente (reply) e rodar capabilities nativas auditadas (transfer/resolve), com o gate live/shadow.
# NÃO decide QUE ação tomar (isso é do dispatch no Gateway) — só EXECUTA e registra (ai_events +
# CapabilityExecution). Contexto do run injetado no initialize; `run` (o Ai::Run) passa por método,
# pois só a CapabilityExecution precisa dele (ai_run_id). Emite os MESMOS ai_events de antes.
#
# ATENÇÃO: recebe `acts_live` por injeção — logo o Gateway só pode criar este dispatcher DEPOIS de
# resolver @acts_live (após o department). Todos os call-sites do run são posteriores a isso.
class Ai::ActionDispatcher
  # Delay incremental entre as partes quando o agente responde "como humano" (várias mensagens curtas
  # simulando alguém digitando). Fase 2 possível: emitir presença "digitando" (uazapi toggle_typing)
  # entre as partes — não implementado agora.
  PART_DELAY_SECONDS = 2

  def initialize(conversation:, account:, mode:, acts_live:, as_human: false)
    @conversation = conversation
    @account = account
    @mode = mode
    @acts_live = acts_live
    # No modo humano (Ai::Agent.identify_as == 'human') a resposta é quebrada em várias mensagens.
    @as_human = as_human
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
  #
  # bypass_handoff: ver Ai::ReplyPolicy#allowed? — repassado pelo Gateway quando ESTE turno (não um
  # anterior) é quem acabou de transferir/atribuir a conversa, pra a mensagem de encerramento do
  # próprio modelo não ser engolida pelo handoff que ele mesmo decidiu neste turno.
  def reply(department, text, bypass_handoff: false)
    return if text.blank?

    # Safety cap: stop replying after the department's max number of AI replies in this
    # conversation (0 = no limit). Counts 'reply.sent' events, so human agent replies don't count.
    max_replies = department.behavior.to_h['max_replies'].to_i
    if max_replies.positive? && ai_replies_count >= max_replies
      emit('reply.skipped', { reason: 'max_replies_reached', max: max_replies })
      return
    end

    state = Ai::ReplyPolicy.effective_reply_state(mode: @mode, department: department, conversation: @conversation,
                                                   bypass_handoff: bypass_handoff)
    if state == :live
      deliver(text)
      # UMA ÚNICA vez por resposta, mesmo quando vira N mensagens: max_replies conta reply.sent e
      # multiplicar quebraria o limite. chars = texto COMPLETO da resposta (antes do split).
      emit('reply.sent', { chars: text.length })
      consume_credit
    else
      reason = Ai::ReplyPolicy.skip_reason(mode: @mode, department: department, conversation: @conversation,
                                            bypass_handoff: bypass_handoff)
      emit('reply.intended', { executed: false, reason: reason })
    end
  rescue StandardError => e
    Rails.logger.error "[Ai::ActionDispatcher#reply] #{e.class}: #{e.message}"
    emit('reply.failed', { error: "#{e.class}: #{e.message}" })
  end

  # Nota INTERNA (privada) para o atendente humano — não vai para o cliente. Usada no handoff por
  # crédito esgotado (billing Fase 2). Erro é logado sem interromper o handoff.
  def internal_note(text)
    return if text.blank?

    Messages::MessageBuilder.new(nil, @conversation, { content: text, private: true }).perform
  rescue StandardError => e
    Rails.logger.error "[Ai::ActionDispatcher#internal_note] #{e.class}: #{e.message}"
  end

  private

  # Envia a resposta. No modo humano quebra em partes por linha em branco (\n\n) e as manda em
  # sequência com delay incremental (a 1ª imediata, as demais agendadas). Se não houver \n\n (modelo
  # não quebrou) ou no modo IA, envia mensagem única — nunca quebra de forma forçada.
  def deliver(text)
    parts = @as_human ? split_parts(text) : [text]
    parts.each_with_index do |part, index|
      if index.zero?
        send_message(part)
      else
        # Fase 2 possível: presença "digitando" antes de cada parte agendada.
        Ai::SplitReplyJob.set(wait: (index * PART_DELAY_SECONDS).seconds)
                         .perform_later(@conversation.id, part)
      end
    end
  end

  # Quebra por 1+ linhas em branco; só divide se sobrar mais de uma parte não-vazia. Caso contrário
  # devolve o texto original inteiro (fallback: mensagem única).
  def split_parts(text)
    parts = text.split(/\n{2,}/).map(&:strip).reject(&:blank?)
    parts.length > 1 ? parts : [text]
  end

  def send_message(content)
    Messages::MessageBuilder.new(nil, @conversation, { content: content, private: false }).perform
  end

  # Consome 1 crédito de IA por resposta EFETIVAMENTE enviada ao cliente (billing Fase 2). nil-safe:
  # conta sem balance/plano não debita nada (fail-open). best-effort: se o saldo já zerou entre o
  # pré-cheque do Gateway e aqui (leitura stale), o rescue deixa passar — o bloqueio primário é o
  # pré-cheque; deixar 1 resposta a mais é aceitável (não trava uma resposta já enviada).
  #
  # BYOK (billing Fase 3): conta com chave própria (custom_llm_api_key) NÃO consome aqui — a resposta na
  # chave do cliente é grátis para a SCNET. O único débito de conta BYOK é o do FALLBACK (chave própria
  # falhou -> chave da SCNET), cobrado explicitamente no Ai::Gateway. Sem esse gate, um saldo
  # auto-provisionado num fallback anterior faria toda resposta com chave própria cobrar indevidamente.
  def consume_credit
    return if @account.feature_enabled?('custom_llm_api_key')

    @account.ai_credit_balance&.consume!(1)
  rescue AiCreditBalance::InsufficientCredits => e
    Rails.logger.info "[Ai::ActionDispatcher] saldo insuficiente ao consumir crédito: #{e.message}"
  end

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
