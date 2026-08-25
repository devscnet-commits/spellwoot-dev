# Traduz a POSIÇÃO abstrata do slider (0-100, "rígido" -> "criativo") para a temperatura real de cada
# provider, interpolando linearmente entre pontos-âncora. O usuário nunca escolhe um número cru: escolhe
# a posição, e cada provider mapeia para a SUA faixa — evitando, por ex., mandar >1.0 pro Anthropic
# (que só aceita 0-1). Ver Ai::ModelRouter (ponto onde a chamada ao LLM é montada).
module Ai
  class TemperatureMapper
    # [posição_slider (0-100), temperatura_real] por provider, em ordem crescente de posição.
    ANCHORS = {
      'openai' => [[0, 0.0], [50, 0.7], [100, 1.3]],
      'anthropic' => [[0, 0.0], [50, 0.5], [100, 1.0]],
      'google' => [[0, 0.3], [50, 1.0], [100, 1.6]],
      # openrouter: mesma faixa da OpenAI como aproximação CONSERVADORA. O modelo real por trás do
      # OpenRouter varia (cada um tem sua própria faixa) e NÃO é tratado nesta versão — se um dia
      # precisar de precisão, resolver por MODELO, não por provider.
      'openrouter' => [[0, 0.0], [50, 0.7], [100, 1.3]]
    }.freeze
    DEFAULT_PROVIDER = 'openai'

    # Achado ao vivo (18/08): modelos de RACIOCÍNIO (o1/o3/o4-mini/gpt-5...) REJEITAM qualquer
    # `temperature` diferente de 1 — a tela de Perfis de Operação deixa digitar o nome do modelo em
    # texto livre (Ai::OperationProfile#supervisor_model), então nada impedia um perfil válido gerar
    # HTTP 400 na primeira conversa real. Prefixo por família (case-insensitive): "o" + dígito
    # (o1, o3, o3-mini, o4-mini...) e "gpt-5" (gpt-5, gpt-5-mini, gpt-5-thinking...). `resolve` devolve
    # nil pra esses — `Ai::ModelRouter`/`Ai::PythonOrchestratorClient` já tratam nil como "omitir o
    # parâmetro", igual já faziam pra provider sem perfil configurado.
    REASONING_MODEL_PATTERN = /\A(o\d|gpt-5)/i

    def self.reasoning_model?(model)
      model.to_s.match?(REASONING_MODEL_PATTERN)
    end

    # Posição (0-100) -> temperatura real do provider. Posição fora da faixa é clampeada a [0, 100].
    # model: quando é um modelo de raciocínio (ver REASONING_MODEL_PATTERN), devolve nil — o parâmetro
    # deve ser OMITIDO da chamada, nunca enviado como 0.0/1.0/etc.
    def self.resolve(provider, position, model: nil)
      return nil if reasoning_model?(model)

      anchors = anchors_for(provider)
      interpolate(anchors, clamp_position(position))
    end

    # Inverso: temperatura real -> posição (0-100) aproximada. Usado para migrar valores legados
    # (supervisor_temperature) para a nova escala, respeitando as âncoras do provider de cada perfil.
    def self.position_for(provider, temperature)
      anchors = anchors_for(provider)
      temp = temperature.to_f
      return anchors.first[0] if temp <= anchors.first[1]
      return anchors.last[0] if temp >= anchors.last[1]

      anchors.each_cons(2) do |(pos0, t0), (pos1, t1)|
        next unless temp >= t0 && temp <= t1

        return (pos0 + (pos1 - pos0) * (temp - t0) / (t1 - t0)).round
      end
      anchors.first[0]
    end

    def self.anchors_for(provider)
      ANCHORS[provider.to_s] || ANCHORS[DEFAULT_PROVIDER]
    end
    private_class_method :anchors_for

    def self.clamp_position(position)
      [[position.to_i, 0].max, 100].min
    end
    private_class_method :clamp_position

    # Interpola a temperatura entre os 2 âncoras que cercam `pos` (que já está em [0,100]).
    def self.interpolate(anchors, pos)
      lower = anchors.select { |p, _| p <= pos }.last
      upper = anchors.find { |p, _| p >= pos }
      return lower[1].to_f if lower[0] == upper[0] # exatamente sobre um âncora

      pos0, t0 = lower
      pos1, t1 = upper
      (t0 + (t1 - t0) * (pos - pos0).to_f / (pos1 - pos0)).round(2)
    end
    private_class_method :interpolate
  end
end
