# Circuit breaker por (conta, provider) para o apagão do provedor de IA (Fase 3 da frente provider-error).
# Com o provedor fora, sem breaker CADA mensagem repete o caminho condenado: chama o modelo, toma erro,
# transfere (Fase 1). Cinquenta mensagens = cinquenta chamadas queimadas. O breaker corta a chamada
# condenada — o Gateway pula direto ao handoff (custo/latência zero), igual ao credit_exhausted? (pré-chamada).
#
# ESTADO em cache (Redis em prod = increment ATÔMICO; null_store em teste => de fato desligado). NÃO guardo
# um Hash de estado reescrito (evitaria o read-modify-write e a corrida entre Sidekiqs): três chaves atômicas
# e independentes — `fails` (só via increment/delete), `open_until` (epoch, write) e `probe` (lock do passe
# half-open via unless_exist). Perder o Redis zera o breaker -> degrada para o comportamento da Fase 2 (seguro).
#
# KILL-SWITCH (saída de emergência): se o breaker abrir por engano (erro transitório mal classificado), a IA
# ficaria muda até alguém ver. ENV['AI_PROVIDER_BREAKER']='off' (ENV vence, senão InstallationConfig de mesmo
# nome) força SEMPRE FECHADO — mesmo idioma do Ai::ModelRouter.decision_schema_enabled?. Default LIGADO;
# fail-open (ligado) em erro de leitura.
#
# ESCOPO (conta, provider), NÃO (conta, provider, modelo): a falha-alvo é cota/billing, que é da CONTA no
# provedor e derruba TODOS os modelos dele — abrir por modelo deixaria o outro modelo queimando chamadas.
class Ai::ProviderBreaker
  # Abre depois de 3 falhas CONSECUTIVAS. Cada falha que chega ao Gateway já sobreviveu aos ~3 retries do
  # ruby_llm, então 3 é sinal limpo (não é um pico transitório).
  FAILURE_THRESHOLD = 3
  # Cooldown curto de propósito: quando o billing volta, o sistema precisa perceber rápido. 1h deixaria a IA
  # parada muito depois de já ter voltado.
  COOLDOWN = 5.minutes
  # Janela deslizante das falhas consecutivas (renovada a cada falha): uma falha isolada decai após um
  # COOLDOWN sem novas — num apagão real elas chegam muito mais juntas que isso, então acumulam até 3 rápido.
  FAILURE_TTL = COOLDOWN
  # open_until SOBREVIVE ao cooldown de propósito: o passe half-open dispara quando now >= open_until COM a
  # chave ainda presente. TTL longo só como auto-cura se um close/reopen se perder (crash de worker).
  OPEN_TTL = 1.hour
  # Enquanto UMA chamada de teste (half-open) está em voo, as demais seguem pulando; se o worker do passe
  # morrer sem registrar, um novo passe é concedido após este TTL.
  PROBE_TTL = 1.minute
  # Nome do InstallationConfig do kill-switch (mesmo do ENV).
  CONFIG_NAME = 'AI_PROVIDER_BREAKER'.freeze

  def initialize(account:, provider:)
    @account = account
    @provider = provider.to_s
  end

  # Estado PRÉ-chamada. :closed = segue normal; :open = PULA a chamada e transfere (Fase 1); :half_open =
  # passe de teste concedido A ESTE worker (segue normal, mas é a chamada que decide fechar/reabrir). O passe
  # é concedido ATOMICAMENTE — só um worker vence o unless_exist; os concorrentes recebem :open e seguem
  # pulando. Kill-switch OFF => sempre :closed.
  def state
    return :closed unless self.class.enabled?

    until_ts = Rails.cache.read(open_until_key)
    return :closed if until_ts.blank?
    return :open if now < until_ts.to_i

    granted = Rails.cache.write(probe_key, 1, unless_exist: true, expires_in: PROBE_TTL)
    granted ? :half_open : :open
  end

  # Timestamp (epoch) de reabertura, para observabilidade no evento breaker_skipped.
  def open_until
    Rails.cache.read(open_until_key)
  end

  # Registra UMA falha de provedor (status 'error'). Contador ATÔMICO (increment — sem read-modify-write).
  # Devolve o payload { consecutive_failures:, reopened: } quando ESTA falha ABRIU (3ª consecutiva) ou REABRIU
  # (falha da chamada de teste half-open) o breaker — o Gateway emite provider.breaker_opened; caso contrário
  # nil (ainda acumulando). Kill-switch OFF => no-op.
  def record_failure
    return nil unless self.class.enabled?

    reopening = Rails.cache.read(probe_key).present? # a falha veio da chamada de teste half-open
    count = Rails.cache.increment(fails_key, 1, expires_in: FAILURE_TTL).to_i
    return open!(count, reopening) if reopening || count >= FAILURE_THRESHOLD

    nil
  end

  # Registra UM sucesso. Zera o contador SEMPRE (só consecutivas contam). Devolve :half_open quando isto
  # FECHOU um breaker que estava em teste (passe half-open) e :success no caso de borda de open_until presente
  # sem probe — o Gateway emite provider.breaker_closed com esse `via`. nil quando não havia nada aberto (um
  # sucesso no meio de 1-2 falhas só reseta o contador, sem evento). Kill-switch OFF => no-op.
  def record_success
    return nil unless self.class.enabled?

    via = if Rails.cache.read(probe_key).present?
            :half_open
          elsif Rails.cache.read(open_until_key).present?
            :success
          end
    Rails.cache.delete(fails_key)
    Rails.cache.delete(probe_key)
    Rails.cache.delete(open_until_key)
    via
  end

  # Kill-switch: valor 'off' força SEMPRE FECHADO. Default LIGADO. Dois caminhos, e o 2º DESARMA SEM DEPLOY:
  # (1) ENV['AI_PROVIDER_BREAKER'] — nível de deploy (mudar env = restart); VENCE se presente.
  # (2) InstallationConfig 'AI_PROVIDER_BREAKER' — linha no banco, flipável em RUNTIME (super admin/console);
  # lido FRESCO a cada turno aqui (find_by direto, SEM cache), então mudar para 'off' vale no PRÓXIMO turno,
  # sem deploy nem restart. É a saída de emergência para um breaker mal calibrado (kill-switch acidental).
  # Fail-open (ligado) em erro de leitura — o breaker é uma proteção; se não der para ler a flag, mantém-na.
  def self.enabled?
    raw = ENV['AI_PROVIDER_BREAKER'].presence ||
          (InstallationConfig.find_by(name: CONFIG_NAME)&.value if defined?(InstallationConfig))
    raw.to_s.strip.downcase != 'off'
  rescue StandardError
    true
  end

  private

  # Abre (ou reabre) o breaker: grava open_until = now + COOLDOWN e LIBERA o probe (para que o próximo
  # cooldown possa conceder um novo passe). Devolve o payload do evento.
  def open!(count, reopening)
    Rails.cache.write(open_until_key, now + COOLDOWN.to_i, expires_in: OPEN_TTL)
    Rails.cache.delete(probe_key)
    { consecutive_failures: count, reopened: reopening }
  end

  def now
    Time.now.to_i
  end

  def key(suffix)
    "ai:provider_breaker:#{@account.id}:#{@provider}:#{suffix}"
  end

  def fails_key
    key('fails')
  end

  def open_until_key
    key('open_until')
  end

  def probe_key
    key('probe')
  end
end
