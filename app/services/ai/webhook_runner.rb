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
    options = { headers: parse_headers(cfg[:headers]), timeout: TIMEOUT }
    if %i[get delete].include?(method)
      options[:query] = input || {}
    else
      options[:body] = (input || {}).to_json
    end

    response = HTTParty.send(method, url, **options)
    { 'status' => response.code, 'body' => safe_parse(response.body) }
  rescue StandardError => e
    raise "webhook falhou: #{e.class}: #{e.message}"
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
