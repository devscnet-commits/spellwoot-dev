# frozen_string_literal: true

module CustomExceptions::Plan
  # Criação que passaria do limite do plano (PlanLimited). 402, igual às travas de limite nos controllers.
  class LimitExceeded < CustomExceptions::Base
    def message
      "Limite de #{::Plan::LIMIT_LABELS.fetch(@data[:key].to_s, @data[:key]).downcase} do seu plano atingido."
    end

    def http_status
      402
    end
  end

  # Recurso/canal que o plano da conta não inclui (PlanChannelGated). 403, igual às travas de módulo nos controllers.
  class FeatureUnavailable < CustomExceptions::Base
    def message
      @data[:message]
    end

    def http_status
      403
    end
  end
end
