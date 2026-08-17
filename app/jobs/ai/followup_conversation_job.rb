# Follow-up de UMA conversa. Recebe conversation_id (enfileirado pelo Ai::FollowupSweepJob),
# resolve o binding/departamento e roda a decisão de follow-up. Toda a lógica de `process` e
# os helpers foram MOVIDOS do antigo sweep, sem alteração — só passaram a rodar isolados e
# em paralelo, no horário/carga certos.
#
# Idempotência: um lock por conversation_id ($alfred) garante que a mesma conversa não é
# processada por dois jobs ao mesmo tempo (somado aos guards por evento já existentes:
# followups_since_incoming / acted?).
class Ai::FollowupConversationJob < ApplicationJob
  queue_as :low

  DEFAULT_INACTIVITY = 30
  LOCK_TTL = 2.minutes

  def perform(conversation_id)
    lock = Redis::LockManager.new
    lock_key = "ai:followup:conv:#{conversation_id}"
    return unless lock.lock(lock_key, LOCK_TTL) # já sendo processada por outro job

    begin
      run(conversation_id)
    rescue StandardError => e
      Rails.logger.error "[Ai::FollowupConversationJob] conv=#{conversation_id} #{e.class}: #{e.message}"
    ensure
      lock.unlock(lock_key)
    end
  end

  private

  # Status elegível pro follow-up: aberta OU pendente — ver comentário de
  # Ai::FollowupSweepJob#candidate_conversations (mesmo critério, duplicado aqui porque este job
  # também pode ser enfileirado fora do sweep/com estado defasado entre o enqueue e a execução).
  ELIGIBLE_STATUSES = %w[open pending].freeze

  # Resolve o contexto da conversa (binding live + departamento) e chama o `process` movido.
  #
  # Achado ao vivo (17/08): o job rodava a cada sweep (mesmas conversas reaparecendo turno a turno,
  # confirmado no log do Sidekiq) mas nunca enviava nada, em ~20-30ms — rápido demais pra ter chegado
  # perto de um envio real, e sem NENHUMA linha de log distinguindo qual guard estava barrando. Cego
  # demais pra debugar ao vivo. Loga o motivo exato de cada saída (aqui e em #process) — infra
  # permanente, não só pra este bug: sem isso, "o follow-up não disparou" sempre exigia adivinhar entre
  # ~8 guards possíveis.
  def run(conversation_id)
    conversation = Conversation.find_by(id: conversation_id)
    if conversation.nil? || ELIGIBLE_STATUSES.exclude?(conversation&.status)
      return log_skip(conversation_id, 'not_eligible_status', status: conversation&.status)
    end
    return log_skip(conversation_id, 'human_assigned') if conversation.assignee_id.present?

    binding = Ai::AgentInbox.live.includes(agent: :account).find_by(inbox_id: conversation.inbox_id)
    return log_skip(conversation_id, 'no_live_binding') if binding.nil?
    unless binding.agent.account&.feature_enabled?('ai_core')
      return log_skip(conversation_id, 'ai_core_disabled', agent_id: binding.agent_id)
    end

    department = resolved_department(conversation, binding)
    return log_skip(conversation_id, 'no_department_resolved', agent_id: binding.agent_id) if department.nil?

    behaviors = Array(department.follow_up.to_h['behaviors'])
    fallback = fallback_actions(department)
    if behaviors.empty? && fallback.empty?
      return log_skip(conversation_id, 'no_followup_or_fallback_configured', department_id: department.id)
    end

    inbox = ::Inbox.find_by(id: binding.inbox_id)
    return log_skip(conversation_id, 'inbox_not_found', inbox_id: binding.inbox_id) if inbox.nil?

    process(binding, department, behaviors, fallback, inbox, conversation, binding.agent.account_id)
  end

  # Bug real ao vivo (isolamento): o follow-up "puxava a mensagem de OUTROS departamentos/agentes".
  # Ai::DepartmentResolver.resolve com message_content: nil (não há mensagem nova no contexto de
  # follow-up) SÓ é determinístico quando há override, mapeamento único de inbox, ou um único
  # department ativo — pra agente MULTI-department sem nada disso, ele cai no is_default/primeiro por
  # POSIÇÃO, que não tem NENHUMA relação com qual department de fato conduziu esta conversa. Fonte de
  # verdade real: Ai::Run#ai_department_id, gravado a cada turno que o Gateway realmente processou
  # (app/services/ai/gateway.rb) — o department que RESOLVEU esta conversa ao vivo, fato histórico, não
  # uma re-classificação às cegas. DepartmentResolver só entra como fallback pra conversa que a IA
  # nunca processou ainda (sem nenhum Ai::Run, ex.: logo após o binding ser criado).
  def resolved_department(conversation, binding)
    last_department_id = Ai::Run.where(conversation_id: conversation.id).where.not(ai_department_id: nil)
                                .order(created_at: :desc).limit(1).pick(:ai_department_id)
    if last_department_id
      # Escopado ao agente/conta DESTE binding — mesma disciplina multi-tenant do override em
      # Ai::DepartmentResolver (nunca confiar num id cru sem validar de quem ele é).
      dept = binding.agent.departments.active.find_by(id: last_department_id)
      return dept if dept
    end

    department, = Ai::DepartmentResolver.resolve(
      agent: binding.agent, inbox_id: conversation.inbox_id, message_content: nil, conversation: conversation
    )
    department
  end

  # ===================================================================================
  # DAQUI PARA BAIXO: MOVIDO VERBATIM DO Ai::FollowupSweepJob (sem editar a lógica)
  # ===================================================================================

  # Achado ao vivo (17/08): tinha um piso de segurança FIXO aqui (MIN_SAFETY_QUIET_MINUTES = 10min),
  # que ignorava silenciosamente qualquer delay_minutes configurado pelo admin abaixo de 10 — um
  # admin que configurasse "1 minuto" nunca via o follow-up dessa etapa disparar antes de 10.
  # Removido a pedido do usuário: o caso que esse piso defendia (mensagem nova do cliente chegando
  # ENTRE o sweep enfileirar e este job rodar) já é coberto com precisão por #awaiting_customer? logo
  # acima — se o cliente respondeu, a ÚLTIMA mensagem passa a ser dele, não nossa, e o guard já barra.
  # O piso fixo era redundante com isso e só atrapalhava configurações curtas legítimas.
  def process(binding, department, behaviors, fallback, inbox, conversation, account_id)
    unless awaiting_customer?(conversation)
      return log_skip(conversation.id, 'last_message_is_customers', department_id: department.id)
    end
    return log_skip(conversation.id, 'human_assigned') if conversation.assignee_id.present? # a human already took over
    # Já entregue a um humano (handoff): a IA/follow-up saem de cena — não retomam nem finalizam.
    return log_skip(conversation.id, 'ai_handoff') if conversation.additional_attributes.to_h['ai_handoff']
    return log_skip(conversation.id, 'already_acted_this_silence') if acted?(conversation) # terminal action already fired

    # No follow-up configured: skip straight to the no-follow-up decision (close_rules).
    if behaviors.empty?
      maybe_run_fallback(department, fallback, inbox, conversation, account_id)
      return
    end

    behavior = active_behavior(behaviors, inbox)
    return log_skip(conversation.id, 'no_matching_behavior_for_now', department_id: department.id) if behavior.nil?

    attempts = Array(behavior['attempts'])
    sent = followups_since_incoming(conversation)

    if sent.count < attempts.size
      maybe_send_attempt(binding, department, attempts, sent, conversation, account_id)
    else
      maybe_run_action(department, behavior, inbox, conversation, account_id, sent)
    end
  end

  # --- Sending the next attempt ------------------------------------------------

  def maybe_send_attempt(binding, department, attempts, sent, conversation, account_id)
    index = sent.count
    delay = attempts[index]['delay_minutes'].to_i
    last_at = sent.maximum(:created_at) || last_incoming_at(conversation) || conversation.last_activity_at
    if last_at && last_at > delay.minutes.ago # not time yet
      return log_skip(conversation.id, 'delay_not_elapsed', last_at: last_at, delay_minutes: delay)
    end

    message = effective_message(attempts, index)
    return log_skip(conversation.id, 'attempt_message_blank', index: index) if message.blank?

    if Ai::ReplyPolicy.allowed?(mode: binding.mode, department: department, conversation: conversation)
      Messages::MessageBuilder.new(nil, conversation, { content: message, private: false }).perform
      emit(account_id, conversation.id, 'followup.sent', { index: index + 1, chars: message.length })
    else
      reason = Ai::ReplyPolicy.skip_reason(mode: binding.mode, department: department, conversation: conversation)
      emit(account_id, conversation.id, 'followup.intended', { index: index + 1, executed: false, reason: reason })
    end
  end

  # Empty messages reuse the last non-empty message of the earlier attempts.
  def effective_message(attempts, index)
    attempts[0..index].reverse_each do |a|
      msg = a['message'].to_s.strip
      return msg if msg.present?
    end
    ''
  end

  # --- Action after the last attempt + inactivity window -----------------------

  def maybe_run_action(department, behavior, inbox, conversation, account_id, sent)
    inactivity = inactivity_minutes(department)
    last_send = sent.maximum(:created_at)
    return if last_send && last_send > inactivity.minutes.ago # still inside the inactivity window

    run_action(behavior['no_response_action'].to_s, department, inbox, conversation, account_id)
  end

  def run_action(action, department, inbox, conversation, account_id)
    case action
    when 'finalize'
      send_close_message(department, conversation)
      conversation.update!(status: :resolved)
      record_action(conversation, account_id, 'finalize')
    when 'discard'
      conversation.update!(status: :resolved)
      record_action(conversation, account_id, 'discard')
    when 'wait'
      record_action(conversation, account_id, 'wait') # hold; recorded so we stop re-evaluating
    when 'wait_business_hours'
      # Hold until business hours, then assign to a human.
      if business_hours_open?(inbox)
        assign_to_human(conversation)
        record_action(conversation, account_id, 'assign', via: 'wait_business_hours')
      end
    else # 'assign' (default)
      assign_to_human(conversation)
      record_action(conversation, account_id, 'assign')
    end
  end

  # --- Fallback: no follow-up configured (close_rules.no_followup_actions) ------

  # Ordered list of decisions for when the inactivity window passes and there is no
  # follow-up to fire. Order = priority; the first one wins.
  def fallback_actions(department)
    Array(department.close_rules.to_h['no_followup_actions']).map(&:to_s).select(&:present?)
  end

  def maybe_run_fallback(department, fallback, inbox, conversation, account_id)
    action = fallback.first
    return if action.blank?

    quiet_at = quiet_since(conversation)
    inactivity = inactivity_minutes(department)
    return if quiet_at && quiet_at > inactivity.minutes.ago # still inside the inactivity window

    run_fallback_action(action, department, inbox, conversation, account_id)
  end

  def run_fallback_action(action, department, inbox, conversation, account_id)
    case action
    when 'finalize'
      send_close_message(department, conversation)
      conversation.update!(status: :resolved)
      record_action(conversation, account_id, 'finalize', via: 'no_followup')
    when 'transfer_human'
      assign_to_human(conversation)
      record_action(conversation, account_id, 'transfer_human', via: 'no_followup')
    when 'transfer_ai'
      # Re-engage the AI proactively: re-run the Gateway anchored on the customer's last
      # message so the AI takes another turn (reply/tool/handoff per its own decision).
      # The Gateway resolves the binding/team routing/mode and respects reply_scope and
      # max_replies on its own.
      reengage_ai(conversation)
      record_action(conversation, account_id, 'transfer_ai', via: 'no_followup')
    else # 'wait'
      record_action(conversation, account_id, 'wait', via: 'no_followup')
    end
  end

  def assign_to_human(conversation)
    conversation.update!(assignee_id: nil) if conversation.assignee_id.present?
  end

  # Proactively hand the turn back to the AI by re-running the Gateway on the customer's
  # last incoming message. No-op when the customer never wrote (nothing to anchor on).
  def reengage_ai(conversation)
    anchor = conversation.messages.incoming.order(:created_at).last
    return if anchor.nil?

    Ai::GatewayRunJob.perform_later(anchor.id)
  end

  def send_close_message(department, conversation)
    message = department.close_rules.to_h['message'].to_s.strip
    return if message.blank?

    Messages::MessageBuilder.new(nil, conversation, { content: message, private: false }).perform
  end

  def record_action(conversation, account_id, action, via: nil)
    emit(account_id, conversation.id, 'followup.action', { action: action, via: via }.compact)
  end

  # --- Context / business hours ------------------------------------------------

  # Comportamento que vale AGORA. Não há ordem manual: "custom" é mais específico e
  # tem prioridade sobre os contextos fixos quando ambos coincidem. Empate entre
  # vários custom/contextos iguais resolve pela ordem de criação (estável).
  def active_behavior(behaviors, inbox)
    inside = business_hours_open?(inbox)
    matching = behaviors.select { |b| behavior_matches?(b, inside, inbox) }
    matching.min_by { |b| b['context'].to_s == 'custom' ? 0 : 1 }
  end

  def behavior_matches?(behavior, inside, inbox)
    case behavior['context'].to_s
    when 'inbox_hours' then inside
    when 'outside_hours' then !inside
    when 'custom' then within_custom_window?(behavior['windows'], inbox)
    else false
    end
  end

  def business_hours_open?(inbox)
    inbox.respond_to?(:available_now?) ? inbox.available_now? : true
  rescue StandardError
    true
  end

  def within_custom_window?(windows, inbox)
    return false if windows.blank?

    now = current_hm(inbox)
    Array(windows).any? do |w|
      start_at = w['start'].to_s
      end_at = w['end'].to_s
      next false if start_at.blank? || end_at.blank?

      start_at <= end_at ? now.between?(start_at, end_at) : (now >= start_at || now <= end_at)
    end
  end

  def current_hm(inbox)
    tz = inbox.respond_to?(:timezone) ? inbox.timezone : nil
    (tz.present? ? Time.current.in_time_zone(tz) : Time.current).strftime('%H:%M')
  rescue StandardError
    Time.current.strftime('%H:%M')
  end

  def inactivity_minutes(department)
    minutes = department.close_rules.to_h['inactivity_minutes'].to_i
    minutes.positive? ? minutes : DEFAULT_INACTIVITY
  end

  # --- Conversation state helpers ----------------------------------------------

  # We only resume when the last real message was ours (the customer went quiet).
  def awaiting_customer?(conversation)
    last = conversation.messages.where(message_type: %i[incoming outgoing]).order(:created_at).last
    last&.outgoing?
  end

  def last_incoming_at(conversation)
    conversation.messages.incoming.maximum(:created_at)
  end

  # When the customer went quiet: the last real message (which, given awaiting_customer?,
  # is ours). Used as the inactivity reference for the no-follow-up fallback.
  def quiet_since(conversation)
    conversation.messages.where(message_type: %i[incoming outgoing]).maximum(:created_at) ||
      conversation.last_activity_at
  end

  # Follow-ups already sent in this silence (since the customer's last incoming message).
  def followups_since_incoming(conversation)
    scope = Ai::Event.where(conversation_id: conversation.id, event_type: 'followup.sent')
    incoming_at = last_incoming_at(conversation)
    incoming_at ? scope.where('created_at > ?', incoming_at) : scope
  end

  # A terminal action already fired in this silence — don't act again.
  def acted?(conversation)
    scope = Ai::Event.where(conversation_id: conversation.id, event_type: 'followup.action')
    incoming_at = last_incoming_at(conversation)
    incoming_at ? scope.where('created_at > ?', incoming_at).exists? : scope.exists?
  end

  def emit(account_id, conversation_id, type, payload)
    Ai::Event.create!(account_id: account_id, conversation_id: conversation_id, event_type: type, payload: payload)
  end

  # Motivo exato de cada `return` silencioso — grepável por "skip=" nos logs do Sidekiq. Retorna nil
  # (mesmo valor que os `return` chamavam antes) pra poder ficar na mesma linha do `return`.
  def log_skip(conversation_id, reason, **details)
    extra = details.map { |k, v| "#{k}=#{v.inspect}" }.join(' ')
    Rails.logger.info "[Ai::FollowupConversationJob] conv=#{conversation_id} skip=#{reason} #{extra}".strip
    nil
  end
end
