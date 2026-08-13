# Fonte única da contagem de uso atual de um limite de plano para uma conta. Mesma lógica antes
# espalhada em controllers (users.count/inboxes.count/ai_agents) — centralizada aqui para o
# enforcement, a tela de plano e o snapshot de overage não divergirem.
#
# Retorna nil quando a chave não tem fonte de contagem hoje (ex.: crm_pipelines não tem modelo).
module Billing
  class LimitUsage
    def self.current_count(account, plan_limit_key)
      case plan_limit_key.to_s
      when 'users' then account.users.count
      when 'inboxes' then account.inboxes.count
      when 'ai_agents' then ::Ai::Agent.where(account_id: account.id).count
      end
    end
  end
end
