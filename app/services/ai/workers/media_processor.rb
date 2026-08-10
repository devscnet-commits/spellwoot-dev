# Invisible worker: turns a message's media attachments into text for the context. Real transcription
# (audio, Whisper) and image analysis (visão via o worker de OCR do perfil) já implementados; se
# faltar config/arquivo/API cai no marcador genérico. `profile` = Ai::OperationProfile do agente,
# necessário para o OCR ler o worker configurado (worker_overrides['ocr']).
class Ai::Workers::MediaProcessor
  # Cap defensivo de tamanho da imagem. WhatsApp comprime (geralmente < 2MB); redimensionar com
  # mini_magick/image_processing fica p/ o futuro se algum provider exigir menor.
  MAX_IMAGE_BYTES = 20 * 1024 * 1024

  # content_type real do blob -> extensão do tempfile enviado ao Whisper. O WhatsApp/uazapi às vezes
  # entrega opus com filename ".mp3"; nomear o arquivo pelo tipo real evita ambiguidade no multipart.
  # Só os formatos aceitos pelo Whisper (o conteúdo é sniffado, mas mantemos coerente).
  AUDIO_EXTENSIONS = {
    'audio/opus' => '.ogg', 'audio/ogg' => '.ogg', 'audio/oga' => '.ogg',
    'audio/mpeg' => '.mp3', 'audio/mp3' => '.mp3', 'audio/mpga' => '.mp3',
    'audio/mp4' => '.m4a', 'audio/m4a' => '.m4a', 'audio/x-m4a' => '.m4a', 'audio/aac' => '.m4a',
    'audio/wav' => '.wav', 'audio/x-wav' => '.wav', 'audio/webm' => '.webm'
  }.freeze

  VISION_SYSTEM_PROMPT = 'Você analisa imagens enviadas por clientes num atendimento. Descreva de ' \
                         'forma OBJETIVA e concisa, em português, o que a imagem mostra e o que é ' \
                         'relevante para o atendimento (ex.: print de erro com a mensagem exibida, ' \
                         'comprovante de pagamento com valor/data, foto de equipamento, documento). ' \
                         'Não invente dados que não estão visíveis. Responda apenas a descrição.'

  # Documentos: PDF de texto (pdf-reader), PDF escaneado -> visão (Opção A: rasteriza a página em imagem
  # e manda ao worker de OCR — input de imagem que qualquer modelo de visão aceita). docx (gem docx).
  # Cap de páginas p/ não estourar custo/latência em docs longos.
  MAX_DOC_PAGES = 10
  PAGE_CAP_NOTE = '[Documento tem mais de 10 páginas — processadas apenas as primeiras 10]'
  # docx não tem "páginas" fixas → cap por caracteres p/ bound de tokens.
  MAX_DOC_CHARS = 15_000
  DOC_TRUNC_NOTE = '[Documento longo — texto truncado]'
  # Extração pobre (PDF escaneado/foto): a camada de texto traz só rótulos do template e muito espaço
  # em branco onde ficam a imagem/campos. Calibrado no caso real (CNH: 387 não-brancos, 62% whitespace).
  # Cai pra visão se: conteúdo (não-brancos) por página < MIN_CONTENT_CHARS_PER_PAGE, OU o texto é
  # majoritariamente espaço em branco (> MAX_WHITESPACE_RATIO). Falso-positivo (texto real curto -> visão)
  # é inofensivo (a visão lê mesmo assim); o perigo é o falso-negativo (escaneado tratado como texto).
  MIN_CONTENT_CHARS_PER_PAGE = 600
  MAX_WHITESPACE_RATIO = 0.55
  # Rasterização PDF->imagem: nº máx. de páginas mandadas à visão (cada uma = 1 chamada/1 Ai::Run) e o
  # DPI. 150 DPI = bom p/ OCR sem estourar tamanho; cap de páginas bounda custo (docs de cliente costumam
  # ter 1-2 págs).
  MAX_VISION_PAGES = 5
  PDF_RASTER_DPI = 150

  # skip_vision: pula SÓ o ramo de imagem (Ai::Gateway passa true quando department.behavior
  # ['python_orchestrator'] está ligado — a OpenAI já recebe a imagem crua via image_url e enxerga
  # nativamente, então rodar o worker de OCR ali é custo/latência duplicado, sem uso). Áudio/documento/
  # vídeo continuam INTACTOS nos dois caminhos — o path Python não tem equivalente nativo pra eles ainda.
  def self.process(message, profile = nil, skip_vision: false)
    attachments = message.attachments.to_a
    return nil if attachments.empty?

    account_id = message.account_id
    conversation_id = message.conversation_id
    attachments.map { |attachment| extract(attachment, account_id, profile, conversation_id, skip_vision: skip_vision) }
               .compact.join("\n").presence
  rescue StandardError => e
    Rails.logger.error "[Ai::Workers::MediaProcessor] #{e.class}: #{e.message}"
    nil
  end

  def self.extract(attachment, account_id, profile = nil, conversation_id = nil, skip_vision: false)
    case attachment.file_type
    when 'audio' then transcribe(attachment, account_id) || '[O cliente enviou um áudio]'
    when 'image' then skip_vision ? nil : (ocr(attachment, account_id, profile, conversation_id) || '[O cliente enviou uma imagem]')
    when 'file'  then document(attachment, account_id, profile, conversation_id) || '[O cliente enviou um arquivo]'
    when 'video' then '[O cliente enviou um vídeo]'
    end
  end

  # Audio transcription via OpenAI Whisper, usando o client ruby-openai (Faraday multipart). A
  # implementação anterior montava o multipart à mão via HTTParty e o OpenAI rejeitava o corpo com
  # "Could not parse multipart form" — ou seja, transcrição NENHUMA passava. A chave é resolvida como
  # no ModelRouter: chave da CONTA (Hub "APIs & Credentials") primeiro, senão a chave da plataforma —
  # assim uma conta que só configurou a OpenAI no Hub (IA própria) transcreve, e a conta com "IA
  # integrada" (sem chave própria) cai na plataforma normalmente. Qualquer falha retorna nil (caller
  # usa o marcador genérico), deixando rastro no log para diferenciar sem-arquivo / sem-chave /
  # erro-API. Áudio sem fala transcritível => text vazio => nil => marcador (sem regressão).
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

    Tempfile.create(['ai-audio', audio_extension(attachment)]) do |tmp|
      tmp.binmode
      tmp.write(attachment.file.download)
      tmp.rewind

      text = whisper_transcribe(api_key, tmp.path)
      return text.present? ? "[Transcrição do áudio]: #{text}" : nil
    end
  rescue StandardError => e
    Rails.logger.error "[Ai::Workers::MediaProcessor] transcrição: #{e.class}: #{e.message}"
    nil
  end

  # Chamada ao Whisper via ruby-openai (multipart correto, Faraday). Retorna o texto transcrito ou nil.
  # Falha de API é logada sem expor o áudio (só a classe/mensagem do erro do OpenAI).
  def self.whisper_transcribe(api_key, path)
    client = OpenAI::Client.new(access_token: api_key)
    file = File.open(path, 'rb')
    begin
      response = client.audio.transcribe(
        parameters: { model: 'whisper-1', file: file, language: 'pt' }
      )
    ensure
      file.close
    end
    response.is_a?(Hash) ? response['text'] : nil
  rescue Faraday::Error => e
    Rails.logger.warn "[Ai::Workers::MediaProcessor] Whisper falhou: #{e.class}#{whisper_error(e)}"
    nil
  end

  # Extensão do tempfile a partir do content_type REAL do blob (o filename do WhatsApp/uazapi às vezes
  # mente: opus entregue como ".mp3"). Cai pra extensão do filename e por fim ".ogg".
  def self.audio_extension(attachment)
    blob = attachment.file.blob
    AUDIO_EXTENSIONS[blob.content_type.to_s.downcase] ||
      File.extname(blob.filename.to_s).presence || '.ogg'
  end

  # Análise de imagem (visão) usando o provider/modelo do WORKER de OCR do perfil (dinâmico, NÃO
  # hardcoded). Lê a imagem direto do ActiveStorage e passa ao ModelRouter (mesma resolução de chave
  # multi-provider do modelo principal). Qualquer falha retorna nil (caller usa o marcador genérico),
  # com log distinto para diferenciar sem-arquivo / sem-worker / erro-de-API — sem logar a imagem.
  def self.ocr(attachment, account_id, profile, conversation_id = nil)
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

    raw = vision_call(provider: provider, model: model, user_message: 'Descreva o conteúdo desta imagem.',
                      account_id: account_id, conversation_id: conversation_id, image: attachment.file)
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

  # Chamada de visão COM DÉBITO: grava um Ai::Run (run_type 'vision_ocr') para auditoria/cobrança —
  # antes NENHUMA chamada de visão (imagem ou PDF) debitava crédito. account_id sempre; conversation_id
  # quando houver (aqui sempre há, é anexo de conversa). Custo via ModelRouter.estimate_cost (call_model
  # devolve tokens mas não custo). Retorna o mesmo hash de call_model.
  def self.vision_call(provider:, model:, user_message:, account_id:, conversation_id:, image:)
    run = Ai::Run.create!(account_id: account_id, conversation_id: conversation_id,
                          run_type: 'vision_ocr', mode: 'worker', worker: 'ocr', status: 'running')
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    raw = Ai::ModelRouter.call_model(
      provider: provider, model: model, system_prompt: VISION_SYSTEM_PROMPT,
      user_message: user_message, account_id: account_id, image: image
    )
    latency_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
    tin = raw[:tokens_in].to_i
    tout = raw[:tokens_out].to_i
    run.update!(provider: provider, model: model, tokens_in: tin, tokens_out: tout,
                cost: Ai::ModelRouter.estimate_cost(model, tin, tout), latency_ms: latency_ms,
                status: raw[:status] == 'error' ? 'error' : 'recorded')
    raw
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
  def self.document(attachment, account_id, profile, conversation_id = nil)
    unless attachment.file.attached?
      Rails.logger.warn '[Ai::Workers::MediaProcessor] documento sem arquivo anexado (download da mídia falhou?), extração pulada'
      return nil
    end

    content_type = attachment.file.blob.content_type.to_s
    filename = attachment.file.blob.filename.to_s.downcase
    if pdf?(content_type, filename)
      extract_pdf(attachment, account_id, profile, conversation_id)
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
  def self.extract_pdf(attachment, account_id, profile, conversation_id = nil)
    reader = PDF::Reader.new(StringIO.new(attachment.file.download))
    page_count = reader.page_count
    pages = reader.pages.first(MAX_DOC_PAGES)
    text = pages.map { |p| p.text.to_s }.join("\n").strip

    if poor_extraction?(text, pages.size)
      pdf_via_vision(attachment, account_id, profile, page_count, conversation_id)
    else
      pdf_text_result(text, page_count)
    end
  end

  # Monta o resultado do PDF de TEXTO (extração boa). Cap de chars + notas de truncamento/páginas.
  def self.pdf_text_result(text, page_count)
    out = "[Documento (PDF)]: #{text.first(MAX_DOC_CHARS)}"
    out += "\n#{DOC_TRUNC_NOTE}" if text.length > MAX_DOC_CHARS
    out += "\n#{PAGE_CAP_NOTE}" if page_count > MAX_DOC_PAGES
    out
  end

  # Extração "pobre" = provável PDF escaneado/foto: pouco conteúdo real (não-brancos) por página OU
  # texto majoritariamente espaço em branco. Calibrado no caso real da CNH (387 não-brancos, 62% ws).
  # Vazio => pobre. NÃO usa alnum-ratio: o cabeçalho da CNH é todo alfabético, não distinguiria.
  def self.poor_extraction?(text, pages_read)
    raw = text.to_s.length
    return true if raw.zero?

    nonws = text.scan(/\S/).length
    ws_ratio = (raw - nonws).to_f / raw
    pages = [pages_read, 1].max
    nonws < pages * MIN_CONTENT_CHARS_PER_PAGE || ws_ratio > MAX_WHITESPACE_RATIO
  end

  # Rasteriza UMA página do PDF em PNG. Usa o binário UNIFICADO `magick` (MiniMagick::Tool::Magick) —
  # o ImageMagick v7 depreciou o subcomando `convert` (e o mini_magick, mesmo detectando o v7, gera
  # `magick convert`, o modo-compat depreciado). `Tool::Magick` emite `magick -density N input.pdf[i]
  # -background white -flatten output.png`, a forma nativa do v7. Precisa de `ghostscript` no container
  # (delegate de PDF — ver Dockerfile*). Retorna um Tempfile PNG (o caller fecha) ou nil se falhar /
  # sem o delegate (degrada pro marcador, sem quebrar). page_index é 0-based.
  def self.pdf_page_to_png(pdf_path, page_index)
    require 'mini_magick'

    png = Tempfile.new(['ai-pdf-page', '.png'])
    png.binmode
    # -density ANTES do input: define a resolução de rasterização do PDF na leitura.
    MiniMagick::Tool::Magick.new do |magick|
      magick.density(PDF_RASTER_DPI)
      magick << "#{pdf_path}[#{page_index}]"
      magick.background('white')
      magick.flatten
      magick << png.path
    end
    png.rewind
    png
  rescue StandardError => e
    Rails.logger.warn "[Ai::Workers::MediaProcessor] rasterização PDF->png falhou (pág #{page_index}): #{e.class}: #{e.message}"
    png&.close!
    nil
  end

  # PDF escaneado -> visão (Opção A): rasteriza as primeiras páginas em PNG e manda cada uma ao worker
  # de OCR do perfil (MESMO caminho da imagem — input de imagem que qualquer modelo de visão aceita).
  # Opt-in: sem worker configurado, não roda. Precisa do delegate de rasterização (ghostscript) no
  # container; sem ele, pdf_page_to_png degrada pra nil e caímos no marcador.
  def self.pdf_via_vision(attachment, account_id, profile, page_count, conversation_id = nil)
    provider, model = ocr_worker(profile)
    if model.blank?
      Rails.logger.warn '[Ai::Workers::MediaProcessor] PDF escaneado mas sem worker de OCR configurado, extração pulada'
      return nil
    end

    vision_pages = [page_count, MAX_VISION_PAGES].min
    texts = pdf_pages_via_vision(attachment, provider, model, account_id, vision_pages, conversation_id)
    return nil if texts.blank?

    out = "[Documento (PDF escaneado)]: #{texts.join("\n").strip}"
    return out unless page_count > vision_pages

    "#{out}\n[Documento tem #{page_count} páginas — processadas apenas as primeiras #{vision_pages} via visão]"
  end

  # Rasteriza e processa cada página; devolve os textos (não-vazios) da visão. Isola o PDF num tempfile
  # p/ o rasterizador. Cada página = 1 chamada de visão independente (o PNG é fechado após uso).
  def self.pdf_pages_via_vision(attachment, provider, model, account_id, vision_pages, conversation_id = nil)
    texts = []
    Tempfile.create(['ai-doc', '.pdf']) do |pdf|
      pdf.binmode
      pdf.write(attachment.file.download)
      pdf.rewind

      (0...vision_pages).each do |i|
        png = pdf_page_to_png(pdf.path, i)
        next unless png

        begin
          raw = vision_call(
            provider: provider, model: model,
            user_message: 'Extraia e descreva o conteúdo desta página de documento.',
            account_id: account_id, conversation_id: conversation_id, image: png.path
          )
          if raw[:status] == 'error'
            Rails.logger.warn "[Ai::Workers::MediaProcessor] visão (PDF pág #{i}) falhou: #{raw[:error]}"
          else
            t = raw[:text].to_s.strip
            texts << t if t.present?
          end
        ensure
          png.close!
        end
      end
    end
    texts
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

  # Mensagem de erro do Whisper para o log — sem PII/áudio. ruby-openai levanta Faraday::Error com
  # .response ({ status:, body: }); o body vem como Hash (json middleware) ou String. Retorna
  # " - <mensagem>" ou ''.
  def self.whisper_error(error)
    body = error.respond_to?(:response) && error.response.is_a?(Hash) ? error.response[:body] : nil
    parsed = body.is_a?(String) ? (JSON.parse(body) rescue nil) : body
    msg = parsed.is_a?(Hash) ? parsed.dig('error', 'message') : nil
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
