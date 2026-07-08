# Invisible worker: turns a message's media attachments into text for the context. Real transcription
# (audio, Whisper) and image analysis (visão via o worker de OCR do perfil) já implementados; se
# faltar config/arquivo/API cai no marcador genérico. `profile` = Ai::OperationProfile do agente,
# necessário para o OCR ler o worker configurado (worker_overrides['ocr']).
class Ai::Workers::MediaProcessor
  # Cap defensivo de tamanho da imagem. WhatsApp comprime (geralmente < 2MB); redimensionar com
  # mini_magick/image_processing fica p/ o futuro se algum provider exigir menor.
  MAX_IMAGE_BYTES = 20 * 1024 * 1024

  VISION_SYSTEM_PROMPT = 'Você analisa imagens enviadas por clientes num atendimento. Descreva de ' \
                         'forma OBJETIVA e concisa, em português, o que a imagem mostra e o que é ' \
                         'relevante para o atendimento (ex.: print de erro com a mensagem exibida, ' \
                         'comprovante de pagamento com valor/data, foto de equipamento, documento). ' \
                         'Não invente dados que não estão visíveis. Responda apenas a descrição.'

  # Documentos: PDF de texto (pdf-reader), PDF escaneado (visão, Opção B — PDF direto ao worker), docx
  # (gem docx). Cap de páginas p/ não estourar custo/latência em docs longos.
  MAX_DOC_PAGES = 10
  PAGE_CAP_NOTE = '[Documento tem mais de 10 páginas — processadas apenas as primeiras 10]'
  # docx não tem "páginas" fixas → cap por caracteres p/ bound de tokens.
  MAX_DOC_CHARS = 15_000
  DOC_TRUNC_NOTE = '[Documento longo — texto truncado]'
  # Heurística texto vs escaneado: abaixo de ~20 chars por página lida, tratamos como PDF escaneado
  # (sem texto selecionável) e caímos no caminho de visão.
  MIN_CHARS_PER_PAGE = 20

  def self.process(message, profile = nil)
    attachments = message.attachments.to_a
    return nil if attachments.empty?

    account_id = message.account_id
    attachments.map { |attachment| extract(attachment, account_id, profile) }.compact.join("\n").presence
  rescue StandardError => e
    Rails.logger.error "[Ai::Workers::MediaProcessor] #{e.class}: #{e.message}"
    nil
  end

  def self.extract(attachment, account_id, profile = nil)
    case attachment.file_type
    when 'audio' then transcribe(attachment, account_id) || '[O cliente enviou um áudio]'
    when 'image' then ocr(attachment, account_id, profile) || '[O cliente enviou uma imagem]'
    when 'file'  then document(attachment, account_id, profile) || '[O cliente enviou um arquivo]'
    when 'video' then '[O cliente enviou um vídeo]'
    end
  end

  # Audio transcription via OpenAI Whisper. A chave é resolvida como no ModelRouter: chave da CONTA
  # (Hub "APIs & Credentials") primeiro, senão a chave da plataforma — assim uma conta que só
  # configurou a OpenAI no Hub (IA própria) transcreve, e a conta com "IA integrada" (sem chave
  # própria) cai na plataforma normalmente. Qualquer falha retorna nil (caller usa o marcador
  # genérico), mas agora deixando rastro no log para diferenciar sem-arquivo / sem-chave / erro-API.
  def self.transcribe(attachment, account_id = nil)
    unless attachment.file.attached?
      # Sem arquivo local: o download da mídia falhou no recebimento (uazapi cai em external_url só).
      Rails.logger.warn '[Ai::Workers::MediaProcessor] áudio sem arquivo anexado (download da mídia falhou?), transcrição pulada'
      return nil
    end

    api_key = openai_key(account_id)
    if api_key.blank?
      Rails.logger.warn '[Ai::Workers::MediaProcessor] sem chave OpenAI (conta nem plataforma), transcrição pulada'
      return nil
    end

    extension = File.extname(attachment.file.blob.filename.to_s).presence || '.ogg'
    Tempfile.create(['ai-audio', extension]) do |tmp|
      tmp.binmode
      tmp.write(attachment.file.download)
      tmp.rewind
      response = HTTParty.post(
        'https://api.openai.com/v1/audio/transcriptions',
        headers: { 'Authorization' => "Bearer #{api_key}" },
        multipart: true,
        body: { model: 'whisper-1', file: tmp }
      )
      unless response.success?
        # Falha REAL de API (auth, formato, tamanho) — não logamos o áudio, só o status/erro do Whisper.
        Rails.logger.warn "[Ai::Workers::MediaProcessor] Whisper falhou: HTTP #{response.code}#{whisper_error(response)}"
        return nil
      end

      text = response.parsed_response.is_a?(Hash) ? response.parsed_response['text'] : nil
      return text.present? ? "[Transcrição do áudio]: #{text}" : nil
    end
  rescue StandardError => e
    Rails.logger.error "[Ai::Workers::MediaProcessor] transcrição: #{e.class}: #{e.message}"
    nil
  end

  # Análise de imagem (visão) usando o provider/modelo do WORKER de OCR do perfil (dinâmico, NÃO
  # hardcoded). Lê a imagem direto do ActiveStorage e passa ao ModelRouter (mesma resolução de chave
  # multi-provider do modelo principal). Qualquer falha retorna nil (caller usa o marcador genérico),
  # com log distinto para diferenciar sem-arquivo / sem-worker / erro-de-API — sem logar a imagem.
  def self.ocr(attachment, account_id, profile)
    unless attachment.file.attached?
      Rails.logger.warn '[Ai::Workers::MediaProcessor] imagem sem arquivo anexado (download da mídia falhou?), OCR pulado'
      return nil
    end

    provider, model = ocr_worker(profile)
    if model.blank?
      # OCR/visão é opt-in (mais caro): sem worker configurado no perfil, não roda.
      Rails.logger.warn '[Ai::Workers::MediaProcessor] sem worker de OCR configurado no perfil, OCR pulado'
      return nil
    end

    if attachment.file.blob.byte_size > MAX_IMAGE_BYTES
      Rails.logger.warn "[Ai::Workers::MediaProcessor] imagem grande demais (#{attachment.file.blob.byte_size} bytes), OCR pulado"
      return nil
    end

    raw = Ai::ModelRouter.call_model(
      provider: provider, model: model,
      system_prompt: VISION_SYSTEM_PROMPT,
      user_message: 'Descreva o conteúdo desta imagem.',
      account_id: account_id, image: attachment.file
    )
    if raw[:status] == 'error'
      Rails.logger.warn "[Ai::Workers::MediaProcessor] visão falhou: #{raw[:error]}"
      return nil
    end

    text = raw[:text].to_s.strip
    text.present? ? "[Imagem]: #{text}" : nil
  rescue StandardError => e
    Rails.logger.error "[Ai::Workers::MediaProcessor] OCR: #{e.class}: #{e.message}"
    nil
  end

  # Worker de OCR do perfil (via Ai::OperationProfile#worker — leitura aninhada centralizada). Sem
  # fallback pro supervisor (diferente do Summary) — visão é opt-in. provider default 'openai' quando
  # só o modelo está setado. Retorna [provider, model] (model nil => não configurado).
  def self.ocr_worker(profile)
    cfg = profile&.worker(:ocr) || {}
    [cfg['provider'].presence || 'openai', cfg['model'].presence]
  end

  # Extração de documento (PDF texto/escaneado + docx). Tipos não suportados (xlsx/txt/...) ou falha
  # => nil => marcador. Logs distintos: sem-arquivo / (escaneado) sem-worker / erro de processamento.
  def self.document(attachment, account_id, profile)
    unless attachment.file.attached?
      Rails.logger.warn '[Ai::Workers::MediaProcessor] documento sem arquivo anexado (download da mídia falhou?), extração pulada'
      return nil
    end

    content_type = attachment.file.blob.content_type.to_s
    filename = attachment.file.blob.filename.to_s.downcase
    if pdf?(content_type, filename)
      extract_pdf(attachment, account_id, profile)
    elsif docx?(content_type, filename)
      extract_docx(attachment)
    end
  rescue StandardError => e
    Rails.logger.error "[Ai::Workers::MediaProcessor] documento: #{e.class}: #{e.message}"
    nil
  end

  # PDF: tenta texto real (pdf-reader, primeiras MAX_DOC_PAGES páginas). Vazio/curto demais => PDF
  # escaneado => visão (Opção B: manda o PDF INTEIRO ao worker; ruby_llm aceita PDF nativo, sem
  # rasterizar/poppler). Cap real por página no caminho escaneado exigiria rasterização (futuro); por
  # ora anexamos só a nota de >10 páginas.
  def self.extract_pdf(attachment, account_id, profile)
    reader = PDF::Reader.new(StringIO.new(attachment.file.download))
    page_count = reader.page_count
    pages = reader.pages.first(MAX_DOC_PAGES)
    text = pages.map { |p| p.text.to_s }.join("\n").strip

    if text.present? && text.length >= pages.size * MIN_CHARS_PER_PAGE
      out = "[Documento (PDF)]: #{text.first(MAX_DOC_CHARS)}"
      out += "\n#{DOC_TRUNC_NOTE}" if text.length > MAX_DOC_CHARS
      out += "\n#{PAGE_CAP_NOTE}" if page_count > MAX_DOC_PAGES
      out
    else
      scanned_pdf_via_vision(attachment, account_id, profile, page_count)
    end
  end

  # PDF escaneado -> visão. Reusa o worker de OCR do perfil e o ModelRouter (mesma chamada da imagem,
  # só passando o PDF em image:). Opt-in: sem worker configurado, não roda.
  def self.scanned_pdf_via_vision(attachment, account_id, profile, page_count)
    provider, model = ocr_worker(profile)
    if model.blank?
      Rails.logger.warn '[Ai::Workers::MediaProcessor] PDF escaneado mas sem worker de OCR configurado, extração pulada'
      return nil
    end

    raw = Ai::ModelRouter.call_model(
      provider: provider, model: model,
      system_prompt: VISION_SYSTEM_PROMPT,
      user_message: 'Extraia e descreva o conteúdo deste documento.',
      account_id: account_id, image: attachment.file
    )
    if raw[:status] == 'error'
      Rails.logger.warn "[Ai::Workers::MediaProcessor] visão (PDF) falhou: #{raw[:error]}"
      return nil
    end

    text = raw[:text].to_s.strip
    return nil if text.blank?

    out = "[Documento (PDF escaneado)]: #{text}"
    page_count > MAX_DOC_PAGES ? "#{out}\n#{PAGE_CAP_NOTE}" : out
  end

  # docx: texto dos parágrafos (gem docx = rubyzip + nokogiri). Cap por caracteres.
  def self.extract_docx(attachment)
    Tempfile.create(['ai-doc', '.docx']) do |tmp|
      tmp.binmode
      tmp.write(attachment.file.download)
      tmp.rewind
      doc = Docx::Document.open(tmp.path)
      text = doc.paragraphs.map(&:text).reject(&:blank?).join("\n").strip
      return nil if text.blank?

      out = "[Documento (docx)]: #{text.first(MAX_DOC_CHARS)}"
      text.length > MAX_DOC_CHARS ? "#{out}\n#{DOC_TRUNC_NOTE}" : out
    end
  end

  def self.pdf?(content_type, filename)
    content_type == 'application/pdf' || filename.end_with?('.pdf')
  end

  def self.docx?(content_type, filename)
    content_type == 'application/vnd.openxmlformats-officedocument.wordprocessingml.document' ||
      filename.end_with?('.docx')
  end

  # Mensagem de erro do Whisper (OpenAI devolve {"error":{"message":...}}) para o log — sem PII/áudio.
  def self.whisper_error(response)
    msg = response.parsed_response.is_a?(Hash) ? response.parsed_response.dig('error', 'message') : nil
    msg.present? ? " - #{msg}" : ''
  rescue StandardError
    ''
  end

  # Resolução da chave OpenAI: conta (Hub) primeiro, senão plataforma. Espelha o Ai::ModelRouter.
  def self.openai_key(account_id = nil)
    account_openai_key(account_id) || platform_openai_key
  end

  # Chave OpenAI da conta pelo Hub "APIs & Credentials" (account→global→ENV via IntegrationSettings).
  def self.account_openai_key(account_id)
    return nil if account_id.blank? || !defined?(IntegrationSettingsService)

    IntegrationSettingsService.get_config(account_id, 'openai')['apiKey'].presence
  rescue StandardError => e
    Rails.logger.warn "[Ai::Workers::MediaProcessor] lookup da chave OpenAI da conta falhou: #{e.class}: #{e.message}"
    nil
  end

  def self.platform_openai_key
    value = (InstallationConfig.find_by(name: 'CAPTAIN_OPEN_AI_API_KEY')&.value if defined?(InstallationConfig))
    value.presence || ENV.fetch('OPENAI_API_KEY', nil)
  rescue StandardError
    ENV.fetch('OPENAI_API_KEY', nil)
  end
end
