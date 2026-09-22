# Interruptor do modo SOMBRA (observação sem resposta). Desligado por padrão.
#
# Sombra não é grátis: o turno faz a chamada REAL ao modelo e só deixa de entregar a resposta. Duas
# rotas gastavam token sem produzir nada para o cliente:
#   1. Ai::ShadowEvalJob — auditoria de qualidade disparada ao resolver uma conversa. Por desenho
#      audita também conversa tratada por HUMANO (Ai::Shadow#scope['observe_human']), então conversa
#      entre duas pessoas era processada pelo modelo.
#   2. Ai::GatewayRunJob — todo binding cujo modo efetivo não é 'live' roda o Gateway inteiro. Basta
#      uma IA vinculada à caixa sem a posse do time da conversa para o turno ser cobrado duas vezes.
#
# Achado em produção: consumo da chave da OpenAI sem nenhuma sombra configurada de propósito. Enquanto
# a regra não for revista, o padrão é NÃO rodar — ligar é uma decisão explícita, não um efeito colateral
# de vincular uma IA a mais numa caixa.
#
# Ligar: InstallationConfig 'AI_SHADOW_ENABLED' = true (Super Admin), ou a env AI_SHADOW_ENABLED.
class Ai::ShadowPolicy
  CONFIG_NAME = 'AI_SHADOW_ENABLED'.freeze

  # Qualquer falha de leitura resolve para DESLIGADO: um erro de configuração não pode religar gasto.
  def self.enabled?
    raw = (InstallationConfig.find_by(name: CONFIG_NAME)&.value if defined?(InstallationConfig))
    raw = ENV.fetch(CONFIG_NAME, nil) if raw.nil?
    ActiveModel::Type::Boolean.new.cast(raw) || false
  rescue StandardError => e
    Rails.logger.warn "[Ai::ShadowPolicy] leitura falhou, mantendo DESLIGADO: #{e.class}: #{e.message}"
    false
  end
end
