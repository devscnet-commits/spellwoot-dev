# Extraído do Ai::Gateway (quebra do God object — Passo 1): concentra a lógica de handoff/atribuição
# — roteamento IA->IA, resolução do time de destino e entrega a um humano (com fallback offline).
# NÃO decide SE deve transferir (isso é do Ai::HandoffEvaluator), NÃO envia a mensagem de transferência
# e NÃO executa a capability conversation.transfer (isso fica no Gateway) — aqui é só o "para quem / como
# entregar". Recebe o contexto do run por injeção; `decision`/`team_id` variam por chamada. Emite os
# MESMOS ai_events de antes (handoff.routed / handoff.assigned / handoff.assigned_fallback) via emit
# próprio, mantendo o golden master intacto.
class Ai::HandoffCoordinator
  MAX_AI_HOPS = 2

  def initialize(conversation:, account:, agent:, message:)
    @conversation = conversation
    @account = account
    @agent = agent
    @message = message
  end

  # Routes the conversation to another AI agent the model chose (handoff_target), if it is in this
  # agent's allowlist and passes the anti-loop guard. Returns true when routed.
  def route_to_ai(decision)
    target_name = decision['handoff_target'].to_s.strip
    return false if target_name.blank?

    allowed_ids = @agent.respond_to?(:handoff_agent_ids) ? Array(@agent.handoff_agent_ids) : []
    return false if allowed_ids.empty?

    target = ::Ai::Agent.where(account_id: @account.id, id: allowed_ids)
                        .find { |a| (a.assistant_name.presence || a.name).to_s.casecmp?(target_name) }
    return false if target.nil? || target.team_id.blank?

    chain = Array(@conversation.additional_attributes&.dig('ai_handoff_chain'))
    return false if chain.size >= MAX_AI_HOPS # anti-loop: cap on IA->IA hops
    return false if chain.include?(target.id)  # never revisit an agent in this chain

    @conversation.update!(team_id: target.team_id)
    attrs = @conversation.additional_attributes || {}
    attrs['ai_handoff_chain'] = chain + [target.id]
    @conversation.update!(additional_attributes: attrs)

    Ai::GatewayRunJob.perform_later(@message.id)
    emit('handoff.routed', { to_agent_id: target.id, to_team_id: target.team_id, hop: chain.size + 1 })
    true
  rescue StandardError => e
    Rails.logger.error "[Ai::HandoffCoordinator#route_to_ai] #{e.class}: #{e.message}"
    false
  end

  # TIME de destino do handoff. PRIMÁRIO: time configurado no agente (Ai::Agent.team_id) —
  # determinístico, não depende do LLM. FALLBACK: match NORMALIZADO (sem acento, caixa baixa, trim)
  # do handoff_target do modelo contra Team.name. O handoff_target puro deixou de ser o mecanismo
  # primário: o modelo variar o texto (não-determinismo) quebrava a atribuição de forma intermitente.
  def human_team_id(decision)
    target = decision['handoff_target'].to_s.strip
    return @agent.team_id if @agent.team_id.present?

    Rails.logger.info "[Ai::HandoffCoordinator] agente sem team_id; match por nome: #{target.inspect}" if target.present?
    match_team_by_name(target)
  end

  # Match tolerante do nome do time (só fallback, quando o agente não tem team_id).
  def match_team_by_name(name)
    key = normalize(name)
    return nil if key.blank?

    ::Team.where(account_id: @account.id).find { |team| normalize(team.name) == key }&.id
  rescue StandardError => e
    Rails.logger.error "[Ai::HandoffCoordinator#match_team_by_name] #{e.class}: #{e.message}"
    nil
  end

  # Normaliza p/ comparação tolerante: remove acentos (NFKD + drop combining marks), downcase, strip.
  def normalize(str)
    str.to_s.unicode_normalize(:nfkd).gsub(/\p{Mn}/, '').downcase.strip
  end

  # Atribuição feita DEPOIS do trabalho da IA: marca o handoff (reabre), dispara a atribuição NATIVA
  # (v2 síncrona se habilitada; senão round-robin legado) e cai num fallback offline se ninguém pegou —
  # a conversa precisa ter um responsável.
  def assign_human(team_id)
    mark_handed_off
    inbox = @conversation.inbox
    if inbox.auto_assignment_v2_enabled?
      # SÍNCRONO: atribui com o estado online do momento do handoff (evita a janela do job assíncrono).
      AutoAssignment::AssignmentService.new(inbox: inbox).perform_bulk_assignment
    else
      allowed = team_id ? team_assignable_ids(team_id) : inbox.member_ids_with_assignment_capacity
      AutoAssignment::AgentAssignmentService.new(conversation: @conversation, allowed_agent_ids: allowed).perform
    end

    if @conversation.reload.assignee_id.present?
      emit('handoff.assigned', { assignee_id: @conversation.assignee_id, team_id: team_id })
    else
      # Ninguém pego pela presença → rede de segurança (não mais gated por team_id).
      ensure_assignee(team_id)
    end
  rescue StandardError => e
    # Antes o erro era ENGOLIDO (só log) — a mensagem já saiu, mas a atribuição falhava no escuro.
    # Agora emitimos um evento de erro rastreável (status 'error') além do log.
    Rails.logger.error "[Ai::HandoffCoordinator#assign_human] #{e.class}: #{e.message}"
    emit('handoff.assign_failed', { team_id: team_id, error: "#{e.class}: #{e.message}" }, status: 'error')
  end

  private

  # Rede de segurança quando a atribuição nativa (por presença) não pegou ninguém: atribui um membro
  # do TIME resolvido; SEM time, cai em qualquer membro do inbox (comportamento observado quando
  # funciona). Sem candidato algum → handoff.assign_failed visível (não mais falha silenciosa).
  def ensure_assignee(team_id)
    candidate_ids = fallback_candidate_ids(team_id)
    if candidate_ids.empty?
      Rails.logger.warn "[Ai::HandoffCoordinator] handoff sem candidato para atribuir (team_id=#{team_id.inspect})"
      return emit('handoff.assign_failed', { team_id: team_id, reason: 'no_assignable_member' }, status: 'error')
    end

    with_capacity = @conversation.inbox.member_ids_with_assignment_capacity & candidate_ids
    assignee_id = with_capacity.first || candidate_ids.first
    @conversation.update!(assignee_id: assignee_id)
    emit('handoff.assigned_fallback', { assignee_id: assignee_id, team_id: team_id })
  end

  # Candidatos p/ o fallback: membros do time resolvido; sem time, qualquer membro do inbox.
  def fallback_candidate_ids(team_id)
    if team_id
      team = ::Team.find_by(id: team_id, account_id: @account.id)
      team ? team.members.ids : []
    else
      @conversation.inbox.members.ids
    end
  end

  # Marca que a IA entregou e GARANTE status 'open' (a auto-atribuição só pega 'open').
  def mark_handed_off
    attrs = @conversation.additional_attributes || {}
    attrs['ai_handoff'] = true
    @conversation.update!(additional_attributes: attrs, status: :open)
  end

  def team_assignable_ids(team_id)
    team = ::Team.find_by(id: team_id, account_id: @account.id)
    return [] if team.nil?

    @conversation.inbox.member_ids_with_assignment_capacity & team.members.ids
  end

  # Espelha o Ai::Gateway#emit: grava o ai_event na MESMA stream (account/conversation), com
  # ai_run_id nil (os eventos de handoff nunca setavam run_id) — preserva o golden master.
  def emit(type, payload, status: 'ok')
    Ai::Event.create!(
      account_id: @account.id, conversation_id: @conversation.id,
      ai_run_id: nil, event_type: type, payload: payload, status: status
    )
  end
end
