# SLA de UMA conversa. Recebe conversation_id (enfileirado pelo Ai::SlaSweepJob), processa CADA
# binding ativo da inbox (verbatim: o SLA registra intenção p/ shadow também) e roda a decisão
# resolve-ou-intende. Lock por conversation_id garante que a mesma conversa não é processada por
# dois jobs ao mesmo tempo.
#
# Diferença do sweep antigo: o cutoff é recalculado no run time (por binding) e há um re-check de
# inatividade — para não resolver uma conversa que recebeu atividade após o enfileiramento.
class Ai::SlaConversationJob < ApplicationJob
  queue_as :low

  LOCK_TTL = 5.minutes

  def perform(conversation_id)
    lock = Redis::LockManager.new
    lock_key = "ai:sla:conv:#{conversation_id}"
    return unless lock.lock(lock_key, LOCK_TTL) # já sendo processada por outro job

    begin
      run(conversation_id)
    rescue StandardError => e
      Rails.logger.error "[Ai::SlaConversationJob] conv=#{conversation_id} #{e.class}: #{e.message}"
    ensure
      lock.unlock(lock_key)
    end
  end

  private

  def run(conversation_id)
    conversation = Conversation.find_by(id: conversation_id)
    return if conversation.nil? || conversation.status != 'open'

    # Cada binding ativo da inbox — igual ao sweep antigo (que re-consultava status:open por binding).
    Ai::AgentInbox.where(inbox_id: conversation.inbox_id, active: true).includes(:agent).find_each do |binding|
      break if conversation.status != 'open' # já resolvido por um binding anterior -> para

      process(binding, conversation)
    end
  end

  # --- MOVIDO VERBATIM (resolve-ou-intende) + cutoff/re-check por binding no run time ---
  def process(binding, conversation)
    department = binding.agent.departments.active.first
    return if department.nil?

    timeout = department.sla['response_timeout_minutes'].to_i
    return unless timeout.positive?

    # Re-check da inatividade AGORA (cutoff do departamento no run time).
    return if conversation.last_activity_at.blank? || conversation.last_activity_at >= timeout.minutes.ago

    account_id = binding.agent.account_id
    # The per-department auto_attendance toggle is a kill switch for every autonomous action.
    acts_live = binding.mode == 'live' && department.behavior.to_h['auto_attendance'] != false

    if acts_live && department.sla['on_timeout'].to_s == 'resolve'
      Ai::CapabilityRegistry.execute('conversation.resolve', conversation: conversation, input: {})
      conversation.reload # reflete o status p/ o `break` do run
      emit(account_id, conversation.id, 'sla.closed', { executed: true })
    else
      emit(account_id, conversation.id, 'sla.intended', { executed: false, reason: sla_skip_reason(binding, acts_live) })
    end
  end

  # --- movido verbatim ---
  def sla_skip_reason(binding, acts_live)
    return binding.mode unless binding.mode == 'live'

    acts_live ? 'on_timeout_none' : 'auto_attendance_off'
  end

  def emit(account_id, conversation_id, type, payload)
    Ai::Event.create!(account_id: account_id, conversation_id: conversation_id, event_type: type, payload: payload)
  end
end
