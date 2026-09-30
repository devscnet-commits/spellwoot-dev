# Trava de limite do plano na GRAVAÇÃO do registro — vale para todo caminho de criação (tela, API, duplicar,
# importar, integração, job, console), não só para o endpoint que lembrou de checar. Achado ao vivo: o
# "Duplicar" de agente de IA não passava pela trava do create e deixava criar o 11º num plano de 10.
#
# Conta pela fonte única (Billing::LimitUsage) e decide pelo FeatureGate.limit_action (sem plano/limite ou
# ilimitado => libera; paid_overage => libera como excedente; hard_block => bloqueia). Um lock por conta+limite
# serializa criações simultâneas (dois cliques ao mesmo tempo não passam juntos de 10 para 12).
module PlanLimited
  extend ActiveSupport::Concern

  class_methods do
    def plan_limited(limit_key)
      before_create -> { enforce_plan_limit!(limit_key) }
    end
  end

  private

  # Registros criados pelo próprio sistema (ex.: caixa interna de teste da IA) não contam nem travam.
  def plan_limit_exempt?
    false
  end

  def enforce_plan_limit!(limit_key)
    return if account.nil? || plan_limit_exempt?

    # Plano lido na hora (fresh: sem o cache por request do FeatureGate): num console ou job longo o cache
    # guardaria o plano de antes de uma troca — e esta trava roda também fora de request.
    return if FeatureGate.limit_for(account, limit_key, fresh: true)&.max_value.nil?

    self.class.connection.execute("SELECT pg_advisory_xact_lock(#{Zlib.crc32("plan_limit:#{account.id}:#{limit_key}")})")
    count = Billing::LimitUsage.current_count(account, limit_key).to_i + 1
    return unless FeatureGate.limit_action(account, limit_key, count, fresh: true) == :block

    raise CustomExceptions::Plan::LimitExceeded.new(key: limit_key)
  end
end
