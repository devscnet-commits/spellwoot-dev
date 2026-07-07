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

  def perform
    lock = Redis::LockManager.new
    return unless lock.lock(LOCK_KEY, LOCK_TTL) # outro sweep já está rodando

    begin
      candidate_conversations.find_each do |conversation|
        Ai::FollowupConversationJob.perform_later(conversation.id)
      end
    ensure
      lock.unlock(LOCK_KEY)
    end
  end

  private

  # Query estreita e indexada: aberta + sem humano + parada há um tempo + em inbox com IA ativa.
  # Os guards finos (aguardando cliente, ai_handoff, já agiu, comportamento configurado) ficam
  # no job por-conversa — barato e isolado.
  def candidate_conversations
    inbox_ids = eligible_inbox_ids
    return Conversation.none if inbox_ids.empty?

    Conversation
      .where(status: :open, assignee_id: nil, inbox_id: inbox_ids)
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
