require 'ssrf_filter'
require 'ipaddr'
require 'resolv'

# Cliente HTTP de saída SEGURO contra SSRF para chamadas cujo destino é controlado por dados do
# usuário (webhooks de automação/ferramenta, integrações, crawl de site). Roteia TODA requisição
# pela gem `ssrf_filter` (já usada no SafeFetch de upload), que:
#   - resolve o DNS e REJEITA IPs privados/reservados/link-local e o metadata endpoint de nuvem
#     (169.254.169.254) — IPv4 e IPv6, incluindo formas mapeadas/traduzidas;
#   - CONECTA no IP já validado (fecha a janela de DNS rebinding / TOCTOU do padrão resolve-e-conecta);
#   - REVALIDA cada hop de redirect (não só a URL inicial) — antes o crawl seguia redirect cego.
# Motivação: CVE-2026-5205 (endpoint que buscava URL externa sem validar rede interna/metadados).
module Ai::SafeHttp
  SUPPORTED_METHODS = %i[get post put patch delete head].freeze
  DEFAULT_TIMEOUT = 30
  OPEN_TIMEOUT = 5
  MAX_REDIRECTS = 5

  # Erros de conexão/leitura da requisição já validada (a URL passou no filtro, mas a chamada falhou).
  NETWORK_ERRORS = [
    Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNREFUSED, Errno::ECONNRESET,
    Errno::EHOSTUNREACH, Errno::ETIMEDOUT, OpenSSL::SSL::SSLError, IOError
  ].freeze

  class Error < StandardError; end
  # URL barrada pelo filtro: IP privado/reservado/metadados, scheme inválido, redirect inseguro,
  # CRLF em header, DNS não resolvido, etc. É a defesa contra SSRF — nunca deve virar requisição.
  class BlockedUrlError < Error; end
  # Falha de rede ao buscar uma URL que JÁ passou na validação (timeout, conexão recusada, TLS...).
  class RequestError < Error; end

  # Objeto de retorno compatível com o que os callers já liam do response do HTTParty:
  # `.code` (Integer, ex.: 200) e `.body` (String). Os callers seguem fazendo o parse manual.
  Response = Struct.new(:code, :body)

  # Validação só do destino, sem fazer a requisição: para URLs que o cliente CADASTRA e que o servidor chama
  # depois por outro cliente HTTP (ex.: endereço do servidor UazAPI/Evolution em APIs & Credenciais). Aceita só
  # http(s) cujo host resolve apenas para IPs públicos — barra localhost, rede interna, link-local e o endpoint de
  # metadados da nuvem. Host que não resolve também é barrado.
  BLOCKED_RANGES = %w[0.0.0.0/8 100.64.0.0/10 192.0.0.0/24 198.18.0.0/15 224.0.0.0/3 ::/128 64:ff9b::/96].map { |r| IPAddr.new(r) }.freeze

  def self.public_url?(url)
    uri = URI.parse(url.to_s.strip)
    return false unless %w[http https].include?(uri.scheme) && uri.host.present?

    addresses = Resolv.getaddresses(uri.host)
    addresses.any? && addresses.all? { |address| public_ip?(IPAddr.new(address)) }
  rescue URI::InvalidURIError, IPAddr::InvalidAddressError
    false
  end

  def self.public_ip?(ip)
    ip = ip.native if ip.ipv4_mapped?
    return false if ip.private? || ip.loopback? || ip.link_local?

    BLOCKED_RANGES.none? { |range| range.family == ip.family && range.include?(ip) }
  end

  # Executa a requisição validando o destino contra SSRF.
  #   method  - :get/:post/:put/:patch/:delete/:head
  #   url     - destino (validado a cada hop de redirect)
  #   headers - Hash de cabeçalhos
  #   body    - corpo cru (String, ex.: JSON) para POST/PUT/PATCH
  #   query   - Hash mesclado na query string (GET/DELETE)
  # Levanta BlockedUrlError (destino barrado) ou RequestError (falha de rede). NUNCA vaza a exceção
  # crua da gem/Net::HTTP para o caller.
  def self.request(method, url, headers: {}, body: nil, query: nil, timeout: DEFAULT_TIMEOUT) # rubocop:disable Metrics/ParameterLists
    verb = method.to_s.downcase.to_sym
    raise BlockedUrlError, "método HTTP não suportado: #{method}" unless SUPPORTED_METHODS.include?(verb)

    options = {
      headers: headers || {},
      max_redirects: MAX_REDIRECTS,
      http_options: { open_timeout: OPEN_TIMEOUT, read_timeout: timeout.to_i.clamp(1, 120) }
    }
    options[:body] = body if body
    options[:params] = query if query.present?

    response = SsrfFilter.public_send(verb, url.to_s, options)
    Response.new(response.code.to_i, response.body.to_s)
  rescue SsrfFilter::Error, URI::InvalidURIError => e
    raise BlockedUrlError, e.message
  rescue *NETWORK_ERRORS => e
    raise RequestError, "#{e.class}: #{e.message}"
  end
end
