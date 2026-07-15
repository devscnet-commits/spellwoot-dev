# Performs the outbound HTTP call for an external integration (webhook/Bitrix/ERP/...).
# Generic by config: endpoint + method + auth + headers + payload_template merged with the input.
# Honors retry/timeout. External side effects are not auto-reversible, so rollback isn't supported.
class Ai::IntegrationConnector
  def self.call(link, input: {})
    validate_link!(link)

    body = (link.payload_template || {}).merge(input || {})
    attempt = 0
    begin
      response = request(link, body)
      { 'status' => response.code, 'body' => safe_parse(response.body) }
    rescue Ai::SafeHttp::BlockedUrlError => e
      # Destino barrado pelo filtro SSRF: falha imediata (não faz sentido re-tentar uma URL proibida).
      raise "integration #{link.name} bloqueada por segurança (endpoint não permitido): #{e.message}"
    rescue StandardError => e
      attempt += 1
      retry if attempt <= link.retry_count.to_i
      raise "integration #{link.name} falhou: #{e.class}: #{e.message}"
    end
  end

  def self.validate_link!(link)
    raise 'integration_link ausente' if link.nil?
    raise "integration inativa: #{link.name}" unless link.status == 'active'
    raise 'endpoint ausente' if link.endpoint.blank?
  end

  def self.request(link, body)
    method = (link.http_method.presence || 'POST').downcase.to_sym
    args = { headers: build_headers(link), timeout: link.timeout_seconds.to_i.clamp(1, 60) }
    # GET/DELETE carry parameters in the query string (typical of ERP "consultar" endpoints);
    # the others send a JSON body.
    if %i[get delete].include?(method)
      args[:query] = body
    else
      args[:body] = body.to_json
    end
    # endpoint é controlado pelo usuário (integration_link) → valida contra SSRF. Ver CVE-2026-5205.
    Ai::SafeHttp.request(method, link.endpoint, **args)
  end

  def self.build_headers(link)
    headers = { 'Content-Type' => 'application/json' }.merge(link.headers || {})
    auth = link.auth || {}
    case auth['type']
    when 'bearer'
      headers['Authorization'] = "Bearer #{auth['token']}"
    when 'header'
      headers[auth['header']] = auth['value'] if auth['header'].present?
    end
    headers
  end

  def self.safe_parse(raw)
    JSON.parse(raw)
  rescue StandardError
    raw.to_s.first(1000)
  end
end
