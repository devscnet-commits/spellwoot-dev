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

    binding = resolved_binding(conversation)
    return log_skip(conversation_id, 'no_live_binding') if binding.nil?
    unless binding.agent.account&.feature_enabled?('ai_core')
      return log_skip(conversation_id, 'ai_core_disabled', agent_id: binding.agent_id)
    end

    agent = binding.agent
    behaviors = Array(agent.follow_up.to_h['behaviors'])
    fallback = fallback_actions(agent)
    if behaviors.empty? && fallback.empty?
      return log_skip(conversation_id, 'no_followup_or_fallback_configured', agent_id: agent.id)
    end

    inbox = ::Inbox.find_by(id: binding.inbox_id)
    return log_skip(conversation_id, 'inbox_not_found', inbox_id: binding.inbox_id) if inbox.nil?

    process(binding, agent, behaviors, fallback, inbox, conversation, agent.account_id)
  end

  # Achado ao vivo (18/08): com MAIS de um agente "live" na MESMA inbox (ex.: duas versões da Maya em
  # produção simultaneamente pra teste), o antigo `Ai::AgentInbox.live.find_by(inbox_id:)` — sem
  # NENHUM critério de ordem — devolvia sempre a MESMA linha pra essa inbox, não importa de qual
  # agente fosse a conversa de verdade. Efeito: o follow-up do agente configurado nunca disparava
  # (o job achava que estava lidando com o OUTRO agente, sem follow-up nenhum), e o agente errado
  # nunca via a config certa aplicada à conversa certa. Ai::GatewayRunJob (resposta ao vivo) já
  # resolve isso com um desempate determinístico ([priority, id] entre os elegíveis pela posse de
  # time — ver #select_winner/#eligible_live? lá) — o follow-up não usava nada disso.
  #
  # Corrigido no mesmo espírito de #run (a etapa que descobre qual agente atendeu): para uma conversa que a IA já atendeu,
  # Ai::Run#ai_agent_id é o FATO histórico de qual agente respondeu de verdade — usa ele direto, sem
  # eleição nenhuma. Só cai na eleição por [priority, id] (mesma regra do Gateway, replicada aqui)
  # quando não há Ai::Run ainda (conversa nova, binding acabou de ser criado).
  def resolved_binding(conversation)
    last_agent_id = Ai::Run.where(conversation_id: conversation.id).where.not(ai_agent_id: nil)
                           .order(created_at: :desc).limit(1).pick(:ai_agent_id)
    if last_agent_id
      binding = Ai::AgentInbox.live.includes(agent: :account)
                              .find_by(inbox_id: conversation.inbox_id, ai_agent_id: last_agent_id)
      return binding if binding
    end

    candidates = Ai::AgentInbox.live.includes(agent: :account).where(inbox_id: conversation.inbox_id)
    eligible = candidates.select { |b| team_eligible?(b, conversation.team_id) }
    eligible.min_by { |b| [b.priority.to_i, b.id] }
  end

  # Mesmo critério de posse-de-time que Ai::GatewayRunJob#eligible_live? usa: agente sem time atende
  # qualquer conversa; agente COM time só atende conversa do mesmo time.
  def team_eligible?(binding, conversation_team_id)
    agent_team_id = binding.agent.team_id
    agent_team_id.nil? || (conversation_team_id.present? && conversation_team_id == agent_team_id)
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
  def process(binding, agent, behaviors, fallback, inbox, conversation, account_id)
    unless awaiting_customer?(conversation)
      return log_skip(conversation.id, 'last_message_is_customers', agent_id: agent.id)
    end
    return log_skip(conversation.id, 'human_assigned') if conversation.assignee_id.present? # a human already took over
    # Já entregue a um humano (handoff): a IA/follow-up saem de cena — não retomam nem finalizam.
    return log_skip(conversation.id, 'ai_handoff') if conversation.additional_attributes.to_h['ai_handoff']
    return log_skip(conversation.id, 'already_acted_this_silence') if acted?(conversation) # terminal action already fired

    # No follow-up configured: skip straight to the no-follow-up decision (close_rules).
    if behaviors.empty?
      maybe_run_fallback(agent, fallback, inbox, conversation, account_id)
      return
    end

    behavior = active_behavior(behaviors, inbox)
    return log_skip(conversation.id, 'no_matching_behavior_for_now', agent_id: agent.id) if behavior.nil?

    attempts = Array(behavior['attempts'])
    sent = followups_since_incoming(conversation)

    if sent.count < attempts.size
      maybe_send_attempt(binding, agent, attempts, sent, conversation, account_id)
    else
      maybe_run_action(agent, behavior, inbox, conversation, account_id, sent)
    end
  end

  # --- Sending the next attempt ------------------------------------------------

  def maybe_send_attempt(binding, agent, attempts, sent, conversation, account_id)
    index = sent.count
    delay = attempts[index]['delay_minutes'].to_i
    last_at = sent.maximum(:created_at) || last_incoming_at(conversation) || conversation.last_activity_at
    if last_at && last_at > delay.minutes.ago # not time yet
      return log_skip(conversation.id, 'delay_not_elapsed', last_at: last_at, delay_minutes: delay)
    end

    message = effective_message(attempts, index)
    return log_skip(conversation.id, 'attempt_message_blank', index: index) if message.blank?

    if Ai::ReplyPolicy.allowed?(mode: binding.mode, agent: agent, conversation: conversation)
      Messages::MessageBuilder.new(nil, conversation, { content: message, private: false }).perform
      emit(account_id, conversation.id, 'followup.sent', { index: index + 1, chars: message.length })
      Rails.logger.info "[Ai::FollowupConversationJob] conv=#{conversation.id} sent=true index=#{index + 1}"
    else
      reason = Ai::ReplyPolicy.skip_reason(mode: binding.mode, agent: agent, conversation: conversation)
      emit(account_id, conversation.id, 'followup.intended', { index: index + 1, executed: false, reason: reason })
      log_skip(conversation.id, "reply_policy_#{reason}", mode: binding.mode, agent_id: agent.id)
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

  def maybe_run_action(agent, behavior, inbox, conversation, account_id, sent)
    inactivity = inactivity_minutes(agent)
    last_send = sent.maximum(:created_at)
    return if last_send && last_send > inactivity.minutes.ago # still inside the inactivity window

    run_action(behavior['no_response_action'].to_s, agent, inbox, conversation, account_id)
  end

  def run_action(action, agent, inbox, conversation, account_id)
    case action
    when 'finalize'
      send_close_message(agent, conversation)
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
        assigned = assign_to_human(conversation, agent)
        record_action(conversation, account_id, 'assign', via: 'wait_business_hours', assigned: assigned)
      end
    else # 'assign' (default)
      assigned = assign_to_human(conversation, agent)
      record_action(conversation, account_id, 'assign', assigned: assigned)
    end
  end

  # --- Fallback: no follow-up configured (close_rules.no_followup_actions) ------

  # Ordered list of decisions for when the inactivity window passes and there is no
  # follow-up to fire. Order = priority; the first one wins.
  def fallback_actions(agent)
    Array(agent.close_rules.to_h['no_followup_actions']).map(&:to_s).select(&:present?)
  end

  def maybe_run_fallback(agent, fallback, inbox, conversation, account_id)
    action = fallback.first
    return if action.blank?

    quiet_at = quiet_since(conversation)
    inactivity = inactivity_minutes(agent)
    return if quiet_at && quiet_at > inactivity.minutes.ago # still inside the inactivity window

    run_fallback_action(action, agent, inbox, conversation, account_id)
  end

  def run_fallback_action(action, agent, inbox, conversation, account_id)
    case action
    when 'finalize'
      send_close_message(agent, conversation)
      conversation.update!(status: :resolved)
      record_action(conversation, account_id, 'finalize', via: 'no_followup')
    when 'transfer_human'
      assigned = assign_to_human(conversation, agent)
      record_action(conversation, account_id, 'transfer_human', via: 'no_followup', assigned: assigned)
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

  # Handoff REAL, pelo MESMO caminho do motor principal (Ai::HandoffCoordinator).
  #
  # O que existia aqui era um no-op duplo:
  #   conversation.update!(assignee_id: nil) if conversation.assignee_id.present?
  # (a) a condição NUNCA era verdadeira — este job só roda com assignee_id nil, checado em #run e de
  # novo em #process; (b) mesmo se fosse, `assignee_id = nil` DESATRIBUI, o oposto de atribuir. Ou
  # seja: "Passar para atendente humano" (o no_response_action PADRÃO da tela, ver
  # AiDepartmentDetail.vue) não atribuía ninguém, não apontava time, não marcava ai_handoff — só
  # gravava um followup.action dizendo 'assign'. A partir daí #acted? barrava tudo com
  # already_acted_this_silence e a conversa ficava congelada: aberta, sem humano e sem IA, até o
  # cliente escrever por conta própria. A telemetria afirmava que tinha transferido.
  #
  # human_team_id({}) é o caminho de "a IA não conseguiu rotear" que o coordinator já implementa:
  # target vazio => fallback_handoff_team_id declarado no agente, senão o 1º da whitelist — mesmo
  # destino que loop/stuck/crédito/baixa confiança já usam. Sem time configurado, assign_human alerta
  # (#alert_no_team_configured) em vez de atribuir ninguém em silêncio, que é exatamente a
  # observabilidade que faltava aqui. Vem de brinde o mark_handed_off (impede a IA de voltar a falar
  # por cima do humano) e o resumo de handoff, que este caminho nunca gerou.
  #
  # Devolve se um humano ficou de fato atribuído — quem chama grava isso no evento, pra que
  # followup.action nunca mais afirme uma transferência que não aconteceu.
  def assign_to_human(conversation, agent)
    coordinator = Ai::HandoffCoordinator.new(
      conversation: conversation, account: conversation.account, agent: agent, message: nil
    )
    coordinator.assign_human(coordinator.human_team_id({}), reason: 'followup_timeout')
    conversation.reload.assignee_id.present?
  end

  # Proactively hand the turn back to the AI by re-running the Gateway on the customer's
  # last incoming message. No-op when the customer never wrote (nothing to anchor on).
  def reengage_ai(conversation)
    anchor = conversation.messages.incoming.order(:created_at).last
    return if anchor.nil?

    Ai::GatewayRunJob.perform_later(anchor.id)
  end

  def send_close_message(agent, conversation)
    message = agent.close_rules.to_h['message'].to_s.strip
    return if message.blank?

    Messages::MessageBuilder.new(nil, conversation, { content: message, private: false }).perform
  end

  # assigned: só nas ações que transferem — false grava explicitamente que a transferência NÃO pegou
  # ninguém (compact remove só nil, não false), pra distinguir "transferiu" de "tentou e não achou
  # agente". Era essa distinção que faltava quando #assign_to_human era um no-op silencioso.
  def record_action(conversation, account_id, action, via: nil, assigned: nil)
    emit(account_id, conversation.id, 'followup.action',
         { action: action, via: via, assigned: assigned }.compact)
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

  def inactivity_minutes(agent)
    minutes = agent.close_rules.to_h['inactivity_minutes'].to_i
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
