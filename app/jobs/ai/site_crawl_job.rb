# Fetches a website knowledge source (title holds the URL), extracts the page text into `raw`
# and triggers ingestion so it becomes retrievable. Best-effort: failures are logged AND recorded on
# the source (crawl_status/crawl_error) — antes só o log via Rails.logger.error existia, e a tela nunca
# mostrava nada quando o crawl falhava; a fonte ficava salva com "raw" vazio, parecendo normal.
class Ai::SiteCrawlJob < ApplicationJob
  queue_as :low

  TIMEOUT = 20
  MAX_CHARS = 50_000

  def perform(source_id)
    source = Ai::KnowledgeSource.find_by(id: source_id)
    return if source.nil? || source.kind != 'website'

    url = normalize_url(source.title.to_s.strip)
    return fail!(source, 'URL vazia ou inválida.') if url.blank?

    # url vem de um KnowledgeSource (título editável pelo usuário) → valida contra SSRF. O SafeHttp
    # segue redirects, mas REVALIDA cada hop (antes o follow_redirects: true cru permitia um redirect
    # para 169.254.169.254/rede interna). Ver CVE-2026-5205.
    response = Ai::SafeHttp.request(:get, url, headers: { 'User-Agent' => 'ConexiiaBot/1.0' }, timeout: TIMEOUT)
    text = extract_text(response.body.to_s)
    return fail!(source, 'A página não tem texto para extrair.') if text.blank?

    source.update_columns(raw: text.first(MAX_CHARS), crawl_status: 'ok', crawl_error: nil, # rubocop:disable Rails/SkipsModelValidations
                          updated_at: Time.current)
    Ai::KnowledgeIngestJob.perform_later(source.id)
  rescue StandardError => e
    Rails.logger.error "[Ai::SiteCrawlJob] source=#{source_id} #{e.class}: #{e.message}"
    fail!(source, e.message.to_s.first(500)) if source
  end

  private

  def fail!(source, message)
    source.update_columns(crawl_status: 'failed', crawl_error: message) # rubocop:disable Rails/SkipsModelValidations
  end

  def normalize_url(url)
    return '' if url.blank?

    url.match?(%r{\Ahttps?://}i) ? url : "https://#{url}"
  end

  def extract_text(html)
    doc = Nokogiri::HTML(html)
    doc.css('script, style, noscript, svg, head, nav, footer').remove
    doc.text.gsub(/[ \t]+/, ' ').gsub(/\n{3,}/, "\n\n").strip
  end
end
