# Runs the Gateway for every active agent bound to the message's inbox (shadow + live).
# Mandatory plumbing for the AI runtime (not the optional "shadow" validation feature). The
# binding's mode drives behaviour: shadow records only; live may reply, gated by the department
# reply_scope (off by default, canary for piloting). Background only.
#
# Team routing: when several agents attend the same inbox, only the agent that owns the
# conversation's team replies; the others observe (shadow). Team-less agents attend anything.
class Ai::GatewayRunJob < ApplicationJob
  # Caminho INTERATIVO da IA (cliente esperando resposta): roda em :medium, acima do trabalho
  # genérico (default) e do batch de IA (:low — ingest/crawl/shadow/sweeps/per-conversation).
  # Alinha o "pensar" da IA com o "entregar" (WebhookJob também roda em :medium).
  queue_as :medium

  def perform(message_id, grouped: false)
    message = Message.find_by(id: message_id)
    return if message.blank?
    # Debounce: if the customer kept typing, let the newer message's job handle the group.
    return if grouped && !Ai::MessageGrouping.latest_incoming?(message)

    # Normaliza localização postada como TEXTO (uazapi nativo) num Attachment :location ANTES do Gateway,
    # no MESMO job (sequencial) — o miolo (Ai::TurnCapture#capture_attachment) já consome esse anexo.
    # Idempotente: só cria se a mensagem ainda não tem anexo. Ver Ai::LocationNormalizer.
    Ai::LocationNormalizer.normalize(message)

    content_override = grouped ? Ai::MessageGrouping.grouped_content(message.conversation) : nil
    conversation_team_id = message.conversation&.team_id
    bindings = Ai::AgentInbox.where(inbox_id: message.inbox_id, active: true).includes(:agent).to_a

    # DESEMPATE (frente a — conserto do duplo-envio): entre os bindings LIVE ELEGÍVEIS (mode 'live' +
    # posse-de-time), elege UM por [priority ASC, id ASC] — priority deixa de ser campo morto, id vira
    # desempate documentado (não acidente do find_each). Só o eleito roda; os OUTROS live elegíveis são
    # PULADOS INTEIROS (sem chamada ao modelo — rebaixá-los a shadow DOBRARIA o custo por conversa). Shadow
    # EXPLÍCITO e live-de-outro-time seguem rodando como shadow (observam), como hoje.
    eligible = bindings.select { |b| b.mode == 'live' && eligible_live?(b, conversation_team_id) }
    winner = eligible.min_by { |b| [b.priority.to_i, b.id] }
    emit_priority_tie(message, eligible, winner) if winner

    bindings.each do |binding|
      next if eligible.include?(binding) && winner && binding.id != winner.id # perdedor da eleição: pula

      mode = effective_mode(binding, conversation_team_id)
      Ai::Gateway.new(message: message, agent_inbox: binding, mode: mode, content_override: content_override).run
    end
  end

  private

  def effective_mode(binding, conversation_team_id)
    return binding.mode unless binding.mode == 'live'

    eligible_live?(binding, conversation_team_id) ? 'live' : 'shadow'
  end

  # Um binding LIVE atende ESTA conversa? Agente sem time atende tudo; senão o time da conversa tem de bater.
  # Mesmo critério da posse-de-time do effective_mode (aqui o mode já é 'live').
  def eligible_live?(binding, conversation_team_id)
    agent_team_id = binding.agent.team_id
    agent_team_id.nil? || (conversation_team_id.present? && conversation_team_id == agent_team_id)
  end

  # Mede o empate de CONFIG: >=2 bindings live elegíveis com o MENOR priority disputando a mesma caixa sem
  # priority distinto. NÃO muda o fluxo (o winner já foi eleito por [priority, id]) — só torna visível ao dono.
  # Idempotente por conversa (o empate é estático) para não floodar o stream a cada turno.
  def emit_priority_tie(message, eligible, winner)
    return if eligible.size < 2

    min_priority = winner.priority.to_i
    tied = eligible.select { |b| b.priority.to_i == min_priority }
    return if tied.size < 2

    conversation = message.conversation
    return if conversation.nil?
    return if Ai::Event.exists?(conversation_id: conversation.id, event_type: 'agent.priority_tie')

    Ai::Event.create!(
      account_id: message.account_id, conversation_id: conversation.id, ai_run_id: nil,
      event_type: 'agent.priority_tie', status: 'ok',
      payload: { agent_ids: tied.map(&:ai_agent_id), priority: min_priority, chosen_agent_id: winner.ai_agent_id }
    )
  rescue StandardError => e
    Rails.logger.error "[Ai::GatewayRunJob#emit_priority_tie] #{e.class}: #{e.message}"
  end
end
