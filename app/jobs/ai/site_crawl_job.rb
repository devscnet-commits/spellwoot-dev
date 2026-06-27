# Fetches a website knowledge source (title holds the URL), extracts the page text into `raw`
# and triggers ingestion so it becomes retrievable. Best-effort: failures are logged, not raised.
class Ai::SiteCrawlJob < ApplicationJob
  queue_as :low

  TIMEOUT = 20
  MAX_CHARS = 50_000

  def perform(source_id)
    source = Ai::KnowledgeSource.find_by(id: source_id)
    return if source.nil? || source.kind != 'website'

    url = normalize_url(source.title.to_s.strip)
    return if url.blank?

    response = HTTParty.get(url, timeout: TIMEOUT, follow_redirects: true,
                                 headers: { 'User-Agent' => 'ConexiiaBot/1.0' })
    text = extract_text(response.body.to_s)
    return if text.blank?

    source.update_columns(raw: text.first(MAX_CHARS), updated_at: Time.current) # rubocop:disable Rails/SkipsModelValidations
    Ai::KnowledgeIngestJob.perform_later(source.id)
  rescue StandardError => e
    Rails.logger.error "[Ai::SiteCrawlJob] source=#{source_id} #{e.class}: #{e.message}"
  end

  private

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
