# Dispatcher do follow-up. NÃO faz mais o trabalho inline: apenas seleciona as conversas
# candidatas (query estreita e indexada) e enfileira 1 Ai::FollowupConversationJob por conversa,
# que rodam em paralelo. Um lock ($alfred) garante que só um sweep dispara por vez (sem overlap).
#
# A decisão de follow-up (attempts / ação / fallback) segue idêntica — só foi MOVIDA para o
# job por-conversa (Ai::FollowupConversationJob), sem alterar a lógica.
class Ai::FollowupSweepJob < ApplicationJob
  queue_as :low

  LOCK_KEY = 'ai:followup_sweep'
  # TTL de segurança: se o dispatcher morrer sem liberar, o lock expira e o próximo ciclo roda.
  # Como ele só enfileira (rápido), na prática libera em <1s pelo ensure.
  LOCK_TTL = 2.minutes
  # Só conversas paradas há pelo menos isso — não mexe em conversa "quente".
  MIN_QUIET = 1.minute

  # Reativado (17/08): estava DESATIVADO desde um corte de emergência (follow-up disparando em
  # conversas ativas, interferindo em teste ao vivo) que cortou aqui, o único ponto de entrada, em
  # vez de corrigir a causa raiz — deixado assim (comentário antigo dizia explicitamente "NÃO é o
  # fix"). A causa raiz JÁ FOI corrigida desde então, em
  # Ai::FollowupConversationJob#resolved_department: usa Ai::Run#ai_department_id (o department que
  # REALMENTE conduziu esta conversa, fato histórico) em vez de re-classificar às cegas via
  # DepartmentResolver — DepartmentResolver só entra como fallback pra conversa que a IA nunca
  # processou ainda (sem Ai::Run nenhum, logo sem "instrução de agente antigo" pra vazar). Reativando
  # o sweep agora que o fix downstream já existe.
  def perform
    lock = Redis::LockManager.new
    return unless lock.lock(LOCK_KEY, LOCK_TTL) # outro sweep já está rodando

    begin
      ids = candidate_conversations.pluck(:id)
      # Achado ao vivo (17/08): uma conversa em teste ao vivo, em silêncio, nunca aparecia NENHUMA
      # linha de Ai::FollowupConversationJob pra ela — nem um skip= sequer. Sem log nenhum aqui, não
      # dava pra distinguir "nem virou candidata neste sweep" (bug em #candidate_conversations/
      # #eligible_inbox_ids: status errado, assignee preso, inbox sem binding live, ou
      # last_activity_at ainda "quente") de "virou candidata mas o job por-conversa não rodou". Loga
      # a lista inteira a cada tick — poucos ids, custo desprezível, grepável por "candidates=".
      Rails.logger.info "[Ai::FollowupSweepJob] candidates=#{ids}"
      ids.each { |id| Ai::FollowupConversationJob.perform_later(id) }
    ensure
      lock.unlock(LOCK_KEY)
    end
  end

  private

  # Query estreita e indexada: aberta OU pendente + sem humano + parada há um tempo + em inbox com IA
  # ativa. Os guards finos (aguardando cliente, ai_handoff, já agiu, comportamento configurado) ficam
  # no job por-conversa — barato e isolado.
  #
  # Achado ao vivo (17/08): só :open ficava de fora conversa em :pending — que é exatamente o caso de
  # uso do follow-up (só a IA no controle, cliente aguardando resposta, ninguém assumiu ainda). O
  # próprio follow-up oferece "Passar para atendente humano" como ação de inatividade — não faria
  # sentido essa ação só existir pra conversa :open. :resolved/:snoozed continuam de fora (encerrada,
  # ou explicitamente adormecida por escolha humana — não é o follow-up que deve acordar essa).
  def candidate_conversations
    inbox_ids = eligible_inbox_ids
    return Conversation.none if inbox_ids.empty?

    Conversation
      .where(status: %i[open pending], assignee_id: nil, inbox_id: inbox_ids)
      .where('conversations.last_activity_at < ?', MIN_QUIET.ago)
      .select(:id)
  end

  # Inboxes com um binding "live" cuja conta tem o ai_core ligado (mesma porta de entrada do
  # sweep antigo). Poucos registros (nº de bindings), então resolver em Ruby é barato.
  def eligible_inbox_ids
    Ai::AgentInbox.live.includes(agent: :account).filter_map do |binding|
      binding.inbox_id if binding.agent.account&.feature_enabled?('ai_core')
    end.uniq
  end
end
