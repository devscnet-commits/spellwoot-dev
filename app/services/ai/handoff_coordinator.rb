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

  # Resolve o TIME de destino a partir do handoff_target do modelo (casado por nome do time na conta).
  # nil quando não casa — aí a transferência mantém o time atual e só desatribui.
  def human_team_id(decision)
    name = decision['handoff_target'].to_s.strip
    return nil if name.blank?

    ::Team.where(account_id: @account.id).find { |team| team.name.to_s.casecmp?(name) }&.id
  rescue StandardError => e
    Rails.logger.error "[Ai::HandoffCoordinator#human_team_id] #{e.class}: #{e.message}"
    nil
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
    fallback_assign_team_member(team_id) if team_id && @conversation.reload.assignee_id.blank?
    emit('handoff.assigned', { assignee_id: @conversation.reload.assignee_id, team_id: team_id })
  rescue StandardError => e
    Rails.logger.error "[Ai::HandoffCoordinator#assign_human] #{e.class}: #{e.message}"
  end

  private

  # Rede de segurança: atribui um membro do time (mesmo offline), priorizando quem tem capacidade.
  # Só roda quando a atribuição nativa por presença não encontrou ninguém.
  def fallback_assign_team_member(team_id)
    team = ::Team.find_by(id: team_id, account_id: @account.id)
    return if team.nil?

    member_ids = team.members.ids
    return if member_ids.empty?

    with_capacity = (@conversation.inbox.member_ids_with_assignment_capacity & member_ids)
    assignee_id = with_capacity.first || member_ids.first
    @conversation.update!(assignee_id: assignee_id)
    emit('handoff.assigned_fallback', { assignee_id: assignee_id, team_id: team_id })
  rescue StandardError => e
    Rails.logger.error "[Ai::HandoffCoordinator#fallback_assign_team_member] #{e.class}: #{e.message}"
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
  def emit(type, payload)
    Ai::Event.create!(
      account_id: @account.id, conversation_id: @conversation.id,
      ai_run_id: nil, event_type: type, payload: payload, status: 'ok'
    )
  end
end
