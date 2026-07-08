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

    # (Futuro) Alguns modelos REJEITAM o parâmetro `temperature` (ex.: certos Anthropic mais novos
    # retornam erro se você envia temperatura customizada). Quando isso surgir, listar os modelos aqui
    # e fazer `resolve` retornar nil para eles — o ModelRouter já pula `with_temperature` quando a
    # temperatura é nil, então a chamada não quebra. Vazio hoje (não detectamos nenhum caso); deixado
    # preparado. Espelha o padrão JSON_FORMAT_PROVIDERS do ModelRouter.
    # TEMPERATURE_UNSUPPORTED_MODELS = [].freeze

    # Posição (0-100) -> temperatura real do provider. Posição fora da faixa é clampeada a [0, 100].
    def self.resolve(provider, position)
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
