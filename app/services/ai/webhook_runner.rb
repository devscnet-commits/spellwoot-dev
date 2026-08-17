# Executa a chamada HTTP de uma ferramenta do tipo "webhook".
# Config (ai_tools.webhook_config): { url, method, headers } — headers em texto "Chave: Valor"
# (uma por linha). O input que a IA preencheu vira o corpo (POST/PUT/PATCH) ou query (GET/DELETE).
# Efeito externo não é auto-reversível, então não há rollback.
class Ai::WebhookRunner
  TIMEOUT = 30

  def self.call(config, input: {})
    cfg = (config || {}).with_indifferent_access
    url = cfg[:url].to_s.strip
    raise 'webhook sem URL' if url.blank?

    method = (cfg[:method].presence || 'POST').to_s.downcase.to_sym

    # Ai::SafeHttp valida o destino contra SSRF (IP privado/metadados/redirect inseguro) — a URL é
    # controlada pelo usuário (webhook_config), então nunca deve bater em rede interna. Ver CVE-2026-5205.
    response = Ai::SafeHttp.request(method, url, **request_args(cfg, method, input))
    # Achado ao vivo (ticket 583): sem este check, uma URL configurada errada (ou fora do ar) devolvia
    # 404/500 e Ai::ToolExecutor gravava 'executed'/error: nil do mesmo jeito — a IA nunca via o sinal
    # "error": true (que orchestrator.py normaliza pra toda falha real de tool — ver
    # _normalize_tool_result), então nem avisava o cliente nem parava de fingir sucesso. Só erro de
    # CONEXÃO levantava exceção antes; status HTTP de falha completava a chamada normalmente. 2xx é a
    # única faixa tratada como sucesso.
    raise "HTTP #{response.code}: #{response.body.to_s.first(200)}" unless (200..299).cover?(response.code)

    { 'status' => response.code, 'body' => safe_parse(response.body) }
  rescue Ai::SafeHttp::BlockedUrlError => e
    raise "webhook bloqueado por segurança (URL não permitida): #{e.message}"
  rescue StandardError => e
    raise "webhook falhou: #{e.class}: #{e.message}"
  end

  # Monta headers/timeout + corpo (POST/PUT/PATCH) ou query (GET/DELETE) para o Ai::SafeHttp.
  def self.request_args(cfg, method, input)
    args = { headers: parse_headers(cfg[:headers]), timeout: TIMEOUT }
    if %i[get delete].include?(method)
      args[:query] = input || {}
    else
      args[:body] = (input || {}).to_json
    end
    args
  end

  # Cabeçalhos vêm como texto "Chave: Valor" (uma por linha).
  def self.parse_headers(raw)
    headers = { 'Content-Type' => 'application/json' }
    raw.to_s.each_line do |line|
      key, value = line.split(':', 2)
      headers[key.strip] = value.strip if key.present? && value.to_s.strip.present?
    end
    headers
  end

  def self.safe_parse(raw)
    JSON.parse(raw)
  rescue StandardError
    raw.to_s.first(1000)
  end
end
