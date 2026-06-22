# Performs the outbound HTTP call for an external integration (webhook/Bitrix/ERP/...).
# Generic by config: endpoint + method + auth + headers + payload_template merged with the input.
# Honors retry/timeout. External side effects are not auto-reversible, so rollback isn't supported.
class Ai::IntegrationConnector
  def self.call(link, input: {})
    raise 'integration_link ausente' if link.nil?
    raise "integration inativa: #{link.name}" unless link.status == 'active'
    raise 'endpoint ausente' if link.endpoint.blank?

    body = (link.payload_template || {}).merge(input || {})
    attempt = 0
    begin
      response = request(link, body)
      { 'status' => response.code, 'body' => safe_parse(response.body) }
    rescue StandardError => e
      attempt += 1
      retry if attempt <= link.retry_count.to_i
      raise "integration #{link.name} falhou: #{e.class}: #{e.message}"
    end
  end

  def self.request(link, body)
    method = (link.http_method.presence || 'POST').downcase.to_sym
    options = { headers: build_headers(link), timeout: link.timeout_seconds.to_i.clamp(1, 60) }
    # GET/DELETE carry parameters in the query string (typical of ERP "consultar" endpoints);
    # the others send a JSON body.
    if %i[get delete].include?(method)
      options[:query] = body
    else
      options[:body] = body.to_json
    end
    HTTParty.send(method, link.endpoint, **options)
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
