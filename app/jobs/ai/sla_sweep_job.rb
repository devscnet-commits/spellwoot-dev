# Dispatcher do SLA: seleciona as conversas candidatas (por binding elegível, usando o cutoff
# daquele departamento) e enfileira 1 Ai::SlaConversationJob por conversa, que rodam em paralelo.
# Um lock ($alfred) garante que só um sweep dispara por vez (sem overlap).
#
# A decisão (resolve-ou-intende) segue idêntica — só foi MOVIDA para o job por-conversa.
class Ai::SlaSweepJob < ApplicationJob
  queue_as :low

  LOCK_KEY = 'ai:sla_sweep'
  # TTL de segurança < intervalo do cron (15 min): se o dispatcher morrer sem liberar, o próximo roda.
  LOCK_TTL = 10.minutes

  def perform
    lock = Redis::LockManager.new
    return unless lock.lock(LOCK_KEY, LOCK_TTL) # outro sweep já está rodando

    begin
      candidate_ids.each do |conversation_id|
        Ai::SlaConversationJob.perform_later(conversation_id)
      end
    ensure
      lock.unlock(LOCK_KEY)
    end
  end

  private

  # Ids únicos de conversas abertas e além do SLA — o cutoff varia POR DEPARTAMENTO, então
  # consultamos por binding elegível e unimos num Set. O job por-conversa re-checa no run time.
  def candidate_ids
    ids = Set.new
    eligible_bindings.each do |binding, cutoff|
      ids.merge(
        Conversation.where(inbox_id: binding.inbox_id, status: :open)
                    .where('last_activity_at < ?', cutoff)
                    .pluck(:id)
      )
    end
    ids
  end

  # Bindings ativos (live E shadow — o SLA grava intenção p/ shadow também) com departamento
  # ativo e SLA positivo, cada um com o cutoff do seu departamento (calculado no dispatch p/
  # estreitar; o job recalcula no run time).
  def eligible_bindings
    Ai::AgentInbox.where(active: true).includes(agent: :account).filter_map do |binding|
      department = binding.agent.departments.active.first
      next if department.nil?

      timeout = department.sla['response_timeout_minutes'].to_i
      next unless timeout.positive?

      [binding, timeout.minutes.ago]
    end
  end
end
