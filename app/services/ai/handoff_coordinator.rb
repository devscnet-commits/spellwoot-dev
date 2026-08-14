# Extraído do Ai::Gateway (quebra do God object — Passo 1): concentra a lógica de handoff/atribuição
# — roteamento IA->IA, resolução do time de destino e entrega a um humano (com fallback offline).
# NÃO decide SE deve transferir (isso é do Ai::HandoffEvaluator), NÃO envia a mensagem de transferência
# e NÃO executa a capability conversation.transfer (isso fica no Gateway) — aqui é só o "para quem / como
# entregar". Recebe o contexto do run por injeção; `decision`/`team_id` variam por chamada. Emite os
# MESMOS ai_events de antes (handoff.routed / handoff.assigned / handoff.assigned_fallback) via emit
# próprio, mantendo o golden master intacto.
class Ai::HandoffCoordinator
  MAX_AI_HOPS = 2
  # Tag de visibilidade quando o handoff não acha NENHUM agente atribuível (mesmo padrão dos outros
  # fallbacks: department-override-indisponivel, chave-propria-falhou).
  NO_AGENT_LABEL = 'sem-agente-disponivel'.freeze
  # Tag quando não há NENHUM time configurado para transferência (nem "Time deste agente" nem
  # "Transferir para times"): sinaliza ao dono que faltou configurar, em vez de cair em membro aleatório.
  NO_TEAM_LABEL = 'sem-time-configurado'.freeze
  # reason + texto do "Resumo da transferência" (campo visível na UI) quando não há time configurado.
  NO_TEAM_REASON = 'no_team_configured'.freeze
  NO_TEAM_SUMMARY = 'Nenhum time de atendimento configurado para transferência. Configure em ' \
                    'Atendimentos e transferências para direcionar automaticamente.'.freeze
  # Throttle do e-mail ao admin: 1 aviso por time a cada janela (evita flood quando o mesmo time
  # vazio recebe várias conversas em sequência). Cache-based (perder o estado = no máximo 1 e-mail
  # extra) — barato e sem migração, suficiente para "não spammar".
  NO_AGENT_NOTIFY_TTL = 15.minutes

  def initialize(conversation:, account:, agent:, message:)
    @conversation = conversation
    @account = account
    @agent = agent
    @message = message
  end

  # Roteia a conversa para outra IA que o modelo escolheu (handoff_target), se estiver na whitelist deste
  # agente e passar o anti-loop. Retorna true quando roteou.
  # VENCEDOR FORÇADO, não team_id: grava ai_routed_agent_id (o GatewayRunJob elege ESSA IA, ignorando a
  # eleição por priority) e NÃO toca conversation.team_id — porque team_id é a POSSE HUMANA da conversa, e
  # handoff IA→IA não muda posse humana (quem decide o time humano é a IA de destino, se e quando ELA
  # transferir). A posse persiste até limpar: mark_handed_off (foi p/ humano), resolvida, novo IA→IA
  # (sobrescreve aqui), e o rescue (uma falha não pode prender a conversa numa IA).
  def route_to_ai(decision)
    target_name = decision['handoff_target'].to_s.strip
    return false if target_name.blank?

    allowed_ids = @agent.respond_to?(:handoff_agent_ids) ? Array(@agent.handoff_agent_ids) : []
    return false if allowed_ids.empty?

    target = resolve_ai_target(target_name, allowed_ids) # emite no_match/not_in_inbox e devolve nil quando falha
    return false if target.nil?

    # Anti-loop SEMEADO com o dono atual (@agent): sem isso a origem nunca entrava na cadeia e um A→B→A
    # imediato escapava (ela só guardava os alvos). Revisita de qualquer id barra; MAX_AI_HOPS limita o total.
    chain = Array(@conversation.additional_attributes&.dig('ai_handoff_chain')) | [@agent.id]
    return false if chain.size > MAX_AI_HOPS
    return false if chain.include?(target.id)

    persist_routed_agent(target.id, chain)
    Ai::GatewayRunJob.perform_later(@message.id)
    emit('handoff.routed', { to_agent_id: target.id, hop: chain.size })
    true
  rescue StandardError => e
    Rails.logger.error "[Ai::HandoffCoordinator#route_to_ai] #{e.class}: #{e.message}"
    clear_routed_agent # uma falha não pode prender a conversa numa IA
    false
  end

  # O alvo está vinculado (ativo) à inbox DESTA conversa? O GatewayRunJob só elege entre bindings da inbox
  # (gateway_run_job:27), então um alvo fora dela é inalcançável -> 'not_in_inbox' + handoff humano.
  # A IA-alvo (casa a whitelist por NOME e está na inbox desta conversa), ou nil. Emite o reason da falha:
  # 'no_match' (nome não casa — o modelo inventou) ou 'not_in_inbox' (casou mas fora da inbox — inalcançável).
  # team_id NÃO é mais exigido (o antigo 'matched_no_team' morre com o vencedor forçado).
  def resolve_ai_target(target_name, allowed_ids)
    target = ::Ai::Agent.where(account_id: @account.id, id: allowed_ids)
                        .find { |a| (a.assistant_name.presence || a.name).to_s.casecmp?(target_name) }
    if target.nil?
      emit_ai_target_unmatched(target_name, allowed_ids, 'no_match')
      return nil
    end
    unless target_on_inbox?(target)
      emit_ai_target_unmatched(target_name, allowed_ids, 'not_in_inbox', matched: target.id)
      return nil
    end
    target
  end

  def target_on_inbox?(target)
    ::Ai::AgentInbox.exists?(inbox_id: @message&.inbox_id, ai_agent_id: target.id, active: true)
  end

  def emit_ai_target_unmatched(target_name, allowed_ids, reason, matched: nil)
    payload = { handoff_target: target_name, allowed_agent_ids: allowed_ids, reason: reason }
    payload[:matched_agent_id] = matched if matched
    emit('handoff.ai_target_unmatched', payload)
  end

  def persist_routed_agent(agent_id, chain)
    attrs = @conversation.additional_attributes || {}
    attrs['ai_routed_agent_id'] = agent_id # posse persistente (SEM tocar team_id / posse humana)
    attrs['ai_handoff_chain'] = chain + [agent_id]
    @conversation.update!(additional_attributes: attrs)
  end

  # Limpa a posse forçada (no rescue do route_to_ai). Também é o ponto que o GatewayRunJob usa quando a marca
  # aponta um agente que sumiu da inbox (limpar + eleição normal, não deixar sem resposta).
  def clear_routed_agent
    attrs = @conversation.additional_attributes || {}
    return unless attrs.key?('ai_routed_agent_id')

    attrs.delete('ai_routed_agent_id')
    @conversation.update!(additional_attributes: attrs)
  rescue StandardError => e
    Rails.logger.error "[Ai::HandoffCoordinator#clear_routed_agent] #{e.class}: #{e.message}"
  end

  # TIME de destino do handoff HUMANO, na ordem: 1) setor pedido pelo modelo (handoff_target) casado por
  # NOME — restrito à allowlist do agente quando houver; 2) o default DECLARADO (fallback_handoff_team_id),
  # senão o configured (1º da whitelist "Transferir para times") — resolve o give-up/loop, que chega sem
  # handoff_target; 3) nil.
  #
  # agent.team_id NÃO é destino de handoff — é FILTRO DE ENTRADA (quais conversas o agente atende, via
  # eligible_live? no GatewayRunJob), nascido como "Time (roteamento)"/"Qualquer conversa" na Fase B.2
  # (commit 15833ee04). O `return @agent.team_id` que existia aqui como PRIMEIRA linha (322d8f051, paliativo
  # de "atribuição confiável") ATROPELAVA whitelist + intenção + fallback (matriz H1) e discordava do
  # conclusion_team_id (H7). REMOVIDO: o handoff determinístico agora vem do fallback_handoff_team_id +
  # configured (a máquina de whitelist), fonte ÚNICA de destino — e give-up e conclusão passam a CONCORDAR.
  # team_id segue só como filtro (e como endereço IA->IA em route_to_ai, que usa o team_id do agente-ALVO).
  def human_team_id(decision)
    target = decision['handoff_target'].to_s.strip
    Rails.logger.info "[Ai::HandoffCoordinator] handoff por nome: #{target.inspect}" if target.present?
    matched = match_team_by_name(target)
    return matched if matched

    # (2)+(H8) Nenhum destino DECLARADO resolveu: give-up (target VAZIO — loop/stuck/credit/provider/confiança
    # baixa; o breaker herda por force_provider_handoff) OU intenção-FALHA (o modelo nomeou um setor que NÃO
    # existe na whitelist). Os dois são "a IA não conseguiu rotear" — usa o default DECLARADO no agente
    # (fallback_handoff_team_id, validado); senão o configured (1º da whitelist). Antes só o give-up usava o
    # fallback e a intenção-falha caía no 1º por acidente de ordenação — o mesmo acidente que o fallback mata
    # (matriz H8). A telemetria target_unmatched é PRESERVADA (agora com o destino escolhido, seja fallback
    # ou configured).
    chosen = fallback_team_id || configured_handoff_team_id
    emit('handoff.target_unmatched', { handoff_target: target, chosen_team_id: chosen }) if target.present?
    chosen
  end

  # Default de give-up declarado no AGENTE, VALIDADO na leitura (defesa em profundidade — a escrita já valida
  # via Ai::Agent). id fora da whitelist NÃO-vazia => handoff.fallback_unlisted + cai no configured. Whitelist
  # VAZIA = configuração AUSENTE, NÃO permissão ampla: NÃO honra o fallback (loga aviso, mesmo espírito do
  # PromptCompiler#human_handoff_teams) e cai no comportamento atual — config incompleta não vira autorização.
  # nil quando não há fallback declarado (ou ele não pode ser honrado).
  def fallback_team_id
    fb = @agent.respond_to?(:fallback_handoff_team_id) ? @agent.fallback_handoff_team_id : nil
    return nil if fb.blank?

    ids = Array(@agent.handoff_team_ids).map(&:to_i)
    if ids.blank?
      Rails.logger.warn "[Ai::HandoffCoordinator] fallback_handoff_team_id=#{fb} declarado mas handoff_team_ids " \
                        'VAZIO — não honrado (configuração ausente não é autorização); cai no comportamento atual.'
      return nil
    end
    return fb.to_i if ids.include?(fb.to_i)

    emit('handoff.fallback_unlisted', { team_id: fb, whitelist: ids })
    nil
  end

  # (b)-core — TIME do desfecho DECLARADO pela etapa (step['on_complete']). Fonte primária: team_id DIRETO
  # (a UI é select), VALIDADO contra a whitelist (handoff_team_ids) — defesa em profundidade na LEITURA: um
  # id fora da whitelist (time removido da lista depois de configurado) NÃO roteia para o não-listado; emite
  # conclusion.team_unlisted e cai no configured_handoff_team_id. Fallback de LEITURA p/ config ANTIGA por
  # nome (info['team']) via match_team_by_name (já restrito à whitelist). Whitelist VAZIA = configuração
  # ausente, NÃO permissão ampla: NÃO honra o id declarado (alinha com o fallback H4 e o match_team_by_name
  # H2/#331 — uma regra só para o mesmo estado). Cai em team_unlisted -> configured (nil na vazia). A escrita
  # já rejeita o on_complete fora da whitelist (Ai::Playbook#on_complete_teams_in_whitelist); isto é a rede
  # de LEITURA para config antiga/out-of-band. nil => alerta "sem time".
  def conclusion_team_id(info)
    ids = Array(@agent.handoff_team_ids).map(&:to_i)
    team_id = info['team_id']
    if team_id.present?
      return team_id.to_i if ids.include?(team_id.to_i)

      emit('conclusion.team_unlisted', { team_id: team_id, whitelist: ids })
      return configured_handoff_team_id
    end

    match_team_by_name(info['team'].to_s) || configured_handoff_team_id
  rescue StandardError => e
    Rails.logger.error "[Ai::HandoffCoordinator#conclusion_team_id] #{e.class}: #{e.message}"
    configured_handoff_team_id
  end

  # Match tolerante do nome do time — restrito aos times ELEGÍVEIS: a allowlist handoff_team_ids quando
  # configurada; senão todos os da conta. Assim "a IA só transfere para os times marcados": um setor
  # pedido fora da allowlist não casa e segue para o configured_handoff_team_id.
  def match_team_by_name(name)
    key = normalize(name)
    return nil if key.blank?

    ids = Array(@agent.handoff_team_ids)
    # (H2) Whitelist VAZIA = configuração AUSENTE, NÃO permissão ampla. Antes, ids vazio PULAVA o filtro e
    # varria a conta INTEIRA — um cliente que não marcou nenhum time via a IA transferir para financeiro/
    # jurídico (regra OPOSTA à do fallback para o MESMO estado). Agora alinha com o fallback: vazia => não
    # casa nada (cai no configured, que também é nil), com aviso.
    if ids.blank?
      Rails.logger.warn "[Ai::HandoffCoordinator] match por nome #{name.inspect} com handoff_team_ids VAZIO — " \
                        'whitelist ausente NÃO casa nenhum time (configuração ausente não é permissão ampla).'
      return nil
    end
    ::Team.where(account_id: @account.id, id: ids).find { |team| normalize(team.name) == key }&.id
  rescue StandardError => e
    Rails.logger.error "[Ai::HandoffCoordinator#match_team_by_name] #{e.class}: #{e.message}"
    nil
  end

  # Destino a partir da lista "Transferir para times (humanos)" (handoff_team_ids). Regra simples e
  # robusta: o 1º time NA ORDEM MARCADA na tela (ordem do array, não do banco) COM membro com
  # capacidade; se nenhum tiver, o 1º marcado. Sem round-robin por ora (simplicidade). Vazia => nil
  # (aí entra o alerta de "sem time configurado").
  def configured_handoff_team_id
    ids = Array(@agent.handoff_team_ids)
    return nil if ids.empty?

    # Carrega os Team e REORDENA pela ordem do array (o ActiveRecord voltaria por id) — a ordem dos
    # checkboxes é a intenção do usuário. compact descarta ids de times deletados.
    by_id = ::Team.where(account_id: @account.id, id: ids).index_by(&:id)
    ordered = ids.filter_map { |id| by_id[id] }
    return nil if ordered.empty?

    capacity = @conversation.inbox.member_ids_with_assignment_capacity
    (ordered.find { |t| t.members.ids.intersect?(capacity) } || ordered.first).id
  rescue StandardError => e
    Rails.logger.error "[Ai::HandoffCoordinator#configured_handoff_team_id] #{e.class}: #{e.message}"
    nil
  end

  # Normaliza p/ comparação tolerante: remove acentos (NFKD + drop combining marks), downcase, strip.
  def normalize(str)
    str.to_s.unicode_normalize(:nfkd).gsub(/\p{Mn}/, '').downcase.strip
  end

  # Atribuição feita DEPOIS do trabalho da IA: marca o handoff (reabre), dispara a atribuição NATIVA
  # (v2 síncrona se habilitada; senão round-robin legado) e cai num fallback offline se ninguém pegou —
  # a conversa precisa ter um responsável.
  #
  # reason: quando presente, este handoff é AUTOMÁTICO da IA (loop/credit_exhausted/nativo) e dispara a
  # geração assíncrona do resumo para o atendente. Transferência manual de humano não passa por aqui, e
  # os call-sites sem reason (se houver) não geram resumo. Enfileirado ANTES da atribuição para não
  # depender do resultado dela.
  # Achado 2.3 (auditoria ticket 563, confirmado com teste exploratório): nada impedia esta chamada de
  # rodar DUAS vezes pro MESMO handoff — o caminho normal (ai_step_index nunca avança além da etapa de
  # desfecho) não repete a chamada, mas um retry de webhook/mensagem duplicada concorrente, ANTES do
  # ai_handoff=true desta primeira chamada commitar, conseguia. Efeito real medido: um SEGUNDO
  # Ai::HandoffSummaryJob enfileirado (custo de LLM duplicado + corrida de escrita no resumo) e
  # perform_native_assignment reexecutado (sem garantia de reatribuir a MESMA pessoa). ai_handoff só é
  # setado por #mark_handed_off, aqui dentro — nenhum outro caminho no código o liga (auditado) — então
  # "já true" só pode significar "assign_human já rodou pra esta conversa"; guard seguro, sem falso
  # positivo. Mesma flag que Ai::ReplyPolicy já usa como fonte da verdade de "já entregue".
  def assign_human(team_id, reason: nil)
    return if @conversation.additional_attributes.to_h['ai_handoff']

    mark_handed_off

    # Sem NENHUM time resolvido (nem "Time deste agente", nem allowlist, nem match) e com a caixa tendo
    # membros: NÃO atribuir ninguém em silêncio — nem a atribuição PRIMÁRIA inbox-wide, nem o fallback.
    # É configuração faltando; alerta e para (o dono precisa ver). Ver #alert_no_team_configured. Vem
    # ANTES do enqueue_handoff_summary: o alerta grava o SEU próprio resumo, sem o async genérico (evita
    # a chamada de LLM e o resumo duplicado).
    return alert_no_team_configured if team_id.blank? && @conversation.inbox.members.exists?

    enqueue_handoff_summary(reason)

    # Aponta a conversa para o time resolvido ANTES da atribuição (idempotente — o conversation.transfer
    # pode já ter setado): no v2 (perform_bulk_assignment) o filter_agents_by_team restringe aos membros
    # do time; no legado o team_assignable_ids já restringe. Sem time (nil/blank) é no-op.
    @conversation.update!(team_id: team_id) if team_id.present? && @conversation.team_id != team_id
    perform_native_assignment(team_id)

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

  # Atribuição nativa: v2 síncrono (perform_bulk_assignment, respeita conversation.team_id via
  # filter_agents_by_team) OU round-robin legado restrito aos membros do time resolvido. Extraído do
  # assign_human para mantê-lo enxuto.
  def perform_native_assignment(team_id)
    inbox = @conversation.inbox
    if inbox.auto_assignment_v2_enabled?
      AutoAssignment::AssignmentService.new(inbox: inbox).perform_bulk_assignment
    else
      allowed = team_id ? team_assignable_ids(team_id) : inbox.member_ids_with_assignment_capacity
      AutoAssignment::AgentAssignmentService.new(conversation: @conversation, allowed_agent_ids: allowed).perform
    end
  end

  # Resumo de handoff (para o card do atendente): só em handoff AUTOMÁTICO da IA (reason presente).
  # Assíncrono e best-effort — o handoff já ocorreu; falha aqui não afeta a transferência/atribuição.
  def enqueue_handoff_summary(reason)
    return if reason.blank?

    Ai::HandoffSummaryJob.perform_later(@conversation.id, reason.to_s)
  rescue StandardError => e
    Rails.logger.error "[Ai::HandoffCoordinator#enqueue_handoff_summary] #{e.class}: #{e.message}"
  end

  # Rede de segurança quando a atribuição nativa (por presença) não pegou ninguém: atribui um membro
  # do TIME resolvido; SEM time, cai em qualquer membro do inbox (comportamento observado quando
  # funciona). Sem candidato algum → handoff.assign_failed visível (não mais falha silenciosa).
  def ensure_assignee(team_id)
    candidate_ids = fallback_candidate_ids(team_id)
    return alert_no_assignable_member(team_id) if candidate_ids.empty?

    with_capacity = @conversation.inbox.member_ids_with_assignment_capacity & candidate_ids
    assignee_id = with_capacity.first || candidate_ids.first
    @conversation.update!(assignee_id: assignee_id)
    emit('handoff.assigned_fallback', { assignee_id: assignee_id, team_id: team_id })
  end

  # Sem NENHUM membro atribuível: a conversa ficaria parada, sem dono e sem ninguém sabendo. Torna o
  # problema VISÍVEL — tag na conversa + e-mail ao admin da conta (throttled) — além do evento.
  def alert_no_assignable_member(team_id)
    Rails.logger.warn "[Ai::HandoffCoordinator] handoff sem candidato para atribuir (team_id=#{team_id.inspect})"
    add_label(NO_AGENT_LABEL)
    notify_admin_no_agent(team_id)
    emit('handoff.assign_failed', { team_id: team_id, reason: 'no_assignable_member' }, status: 'error')
  end

  # NENHUM time configurado para transferência (nem "Time deste agente" nem "Transferir para times").
  # O dono PRECISA ver que faltou configurar. Registra o motivo no "Resumo da transferência" (campo
  # VISÍVEL na UI = HandoffSummary.content) + tag + e-mail ao admin + evento rastreável. NÃO atribui um
  # membro aleatório da caixa. Mesmo mecanismo do alert_no_assignable_member (integrado).
  def alert_no_team_configured
    Rails.logger.warn "[Ai::HandoffCoordinator] handoff sem time configurado (agente=#{@agent.id} inbox=#{@conversation.inbox_id})"
    record_no_team_summary
    add_label(NO_TEAM_LABEL)
    notify_admin_no_agent(nil)
    emit('handoff.no_team_configured',
         { inbox_id: @conversation.inbox_id, conversation_id: @conversation.id }, status: 'error')
  end

  # Grava o motivo DIRETO no "Resumo da transferência" (campo visível = HandoffSummary.content), sem
  # chamar o LLM (é config faltando, não precisa de resumo gerado). Idempotente: não duplica o resumo
  # de "sem time" desta conversa se assign_human for reexecutado (retry do Sidekiq).
  def record_no_team_summary
    return if Ai::HandoffSummary.exists?(conversation_id: @conversation.id, reason: NO_TEAM_REASON)

    Ai::HandoffSummary.create!(account_id: @account.id, conversation_id: @conversation.id,
                               reason: NO_TEAM_REASON, content: NO_TEAM_SUMMARY)
  rescue StandardError => e
    Rails.logger.error "[Ai::HandoffCoordinator#record_no_team_summary] #{e.class}: #{e.message}"
  end

  # Tag best-effort (mesmo handler direto dos outros fallbacks de visibilidade).
  def add_label(label)
    Ai::CapabilityRegistry.execute('conversation.add_label', conversation: @conversation,
                                                             input: { 'label' => label })
  rescue StandardError => e
    Rails.logger.error "[Ai::HandoffCoordinator#add_label] #{e.class}: #{e.message}"
  end

  # E-mail ao admin da conta (mesmo mecanismo do aviso de saldo baixo). Throttled por time p/ não
  # spammar. Best-effort: nunca derruba o handoff (a conversa já foi entregue ao time).
  def notify_admin_no_agent(team_id)
    return unless notify_throttle_allows?(team_id)

    team_name = (team_id && ::Team.find_by(id: team_id, account_id: @account.id)&.name).presence || 'sem time'
    AdministratorNotifications::AccountNotificationMailer
      .with(account: @account)
      .handoff_no_agent_available(@conversation, team_name)
      .deliver_later
  rescue StandardError => e
    Rails.logger.error "[Ai::HandoffCoordinator#notify_admin_no_agent] #{e.class}: #{e.message}"
  end

  # 1 e-mail por (conta, time) a cada NO_AGENT_NOTIFY_TTL. Escreve a marca ao permitir.
  def notify_throttle_allows?(team_id)
    key = "ai:handoff_no_agent:#{@account.id}:#{team_id || 'none'}"
    return false if Rails.cache.read(key)

    Rails.cache.write(key, true, expires_in: NO_AGENT_NOTIFY_TTL)
    true
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
    attrs.delete('ai_routed_agent_id') # foi para HUMANO: a posse forçada IA→IA acabou (ponto de limpeza)
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
